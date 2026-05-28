# Romestead on Kubernetes

Deploy the dedicated server with a one-shot install Job, a single-replica Deployment, and a daily backup CronJob.

> All manifests use UID `1000` / GID `1001` and mount the persistent volume at `/mnt/steam` — matching the Compose layout in [`../compose/`](../compose/). The `seccompProfile: Unconfined` + `SYS_NICE` settings are required by DepotDownloader (blocked syscalls) and the renice on the engine thread; do not remove them without testing.

## Quick start

```bash
# 1. Create the namespace (out-of-band — leaves RBAC/policy decisions to you)
kubectl create namespace romestead

# 2. Populate the secret
cp secret.example.yaml secret.yaml
$EDITOR secret.yaml              # set PASSWORD at minimum
kubectl -n romestead apply -f secret.yaml

# 3. Apply the rest of the bundle
kubectl -n romestead apply -k .

# 4. Wait for the install Job to finish before the Deployment is useful
kubectl -n romestead wait --for=condition=complete job/romestead-install --timeout=15m
kubectl -n romestead rollout status deployment/romestead-server

# 5. Verify
kubectl -n romestead exec deploy/romestead-server -- rs health
```

## Branch-switch recipe

Romestead has no public beta channel today, but the plumbing is there. When/if one appears:

```bash
# 1. Patch the secret to the new branch
kubectl -n romestead patch secret romestead-config \
  --type='merge' -p='{"stringData":{"BRANCH":"experimental"}}'

# 2. Re-run the install Job against the new depot
kubectl -n romestead delete job/romestead-install
kubectl -n romestead apply -f install-job.yaml
kubectl -n romestead wait --for=condition=complete job/romestead-install --timeout=15m

# 3. Restart the server so it picks up the refreshed binaries
kubectl -n romestead rollout restart deployment/romestead-server
```

## Sending admin commands

`rs send <command>` writes through the in-container FIFO that Romestead reads as console stdin:

```bash
kubectl -n romestead exec deploy/romestead-server -- rs send save
kubectl -n romestead exec deploy/romestead-server -- rs send "kick <player>"
```

## Pulling a backup off the cluster

The backup CronJob writes into the same PVC (cheap to keep recent snapshots near the data). To pull one to a workstation:

```bash
POD=$(kubectl -n romestead get pod -l app.kubernetes.io/component=server -o name | head -1)
kubectl -n romestead exec "$POD" -- ls /mnt/steam/backups
kubectl -n romestead cp "$POD":/mnt/steam/backups/romestead-<timestamp>.tar.gz ./romestead-backup.tar.gz
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Install Job stuck in `Pending` | PVC not bound — check `kubectl get pvc` and your StorageClass |
| Install Job `Error`, log shows `Access denied` | Anonymous downloads broke; set `STEAM_USER` + `STEAM_PASSWORD` in the Secret (see [`secret.example.yaml`](secret.example.yaml)) |
| Server pod restarts on startup | `startupProbe` failing — bump `failureThreshold` if your cluster is slow, or check `kubectl logs` for engine errors |
| Cannot connect from outside the cluster | `hostNetwork: true` puts the server on the node's NIC — make sure the node firewall lets UDP 8050 through |
| Permission denied on first start | `fix-permissions` initContainer didn't run, or the PVC was previously owned by a different UID — `kubectl exec` and `chown -R 1000:1001 /mnt/steam` |

See [`../.claude/blueprint/checklist-new-game.md`](../.claude/blueprint/checklist-new-game.md) → "Common time-sinks" for the broader debugging matrix.
