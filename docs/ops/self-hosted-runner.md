# Self-hosted GitHub Actions runner for `ha-soak`

The nightly soak workflow at
[.github/workflows/ha-soak.yaml](../../.github/workflows/ha-soak.yaml)
needs a self-hosted runner — GitHub-hosted runners are capped at 6h
and don't have a persistent Kubernetes cluster pointing at a deployed
cube-stack-ha release.

This doc describes one way to set up that runner: as a Kubernetes
Deployment in your ops cluster, with kubeconfig context that lets it
`kubectl` against the same cluster (or a peer) where cube-stack-ha
runs.

## Prerequisites

- A k8s cluster you control (3+ nodes recommended so anti-affinity
  can spread the soak target's 3 routers).
- `cube-stack-ha` already deployed in namespace `cube-ha` on that
  cluster (`make ha-deploy`).
- A GitHub PAT or runner registration token with
  `actions:write,read` on this repo.

## Manifest

Save as `runner.yaml` and adapt the namespaces / secret names for
your environment.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: gha-runners
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cube-soak-runner
  namespace: gha-runners
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cube-soak-runner
  namespace: cube-ha
subjects:
  - kind: ServiceAccount
    name: cube-soak-runner
    namespace: gha-runners
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  # Soak only needs read+delete pods + read services/endpoints. Grant
  # the minimal role; do NOT use cluster-admin.
  name: cube-soak-runner
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cube-soak-runner
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list, watch, delete]
  - apiGroups: [""]
    resources: [pods/portforward]
    verbs: [create]
  - apiGroups: [""]
    resources: [services, endpoints]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [statefulsets]
    verbs: [get, list, watch]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cube-soak-runner
  namespace: gha-runners
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cube-soak-runner
  template:
    metadata:
      labels:
        app: cube-soak-runner
    spec:
      serviceAccountName: cube-soak-runner
      containers:
        - name: runner
          # Use the official actions-runner-controller image, or roll
          # your own. The point is a runner with kubectl + curl + jq +
          # bash already installed.
          image: ghcr.io/actions/actions-runner:latest
          env:
            - name: RUNNER_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: RUNNER_LABELS
              # MUST match the runs-on labels in ha-soak.yaml.
              value: "self-hosted,cube-soak-runner"
            - name: GITHUB_REPO
              value: "agriev/cube-stack-deployment"
            - name: GITHUB_TOKEN
              valueFrom:
                secretKeyRef:
                  name: github-runner-token
                  key: token
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: 2
              memory: 2Gi
```

Apply with:

```bash
# 1. Create the GitHub PAT secret
kubectl -n gha-runners create secret generic github-runner-token \
  --from-literal=token=ghp_...your...pat...

# 2. Apply the manifest
kubectl apply -f runner.yaml

# 3. Verify the runner is registered (check repo settings → Actions → Runners)
```

## Verify

Trigger the workflow manually:

1. GitHub UI → Actions → `ha-soak` → "Run workflow" with
   `duration=600` (10-min smoke).
2. The runner should pick the job up within 30s.
3. After 10 min, the job summary should show "p95 failover" under
   the budget and zero "Over budget" rounds.

## When the soak fails

The workflow uploads `/tmp/ha-soak-*.jsonl` as an artifact. Download
it and:

```bash
# Show the rounds that took longer than the budget
jq -c 'select(.failover_secs > 30)' ha-soak-*.jsonl

# Per-action distribution of failover times
jq -r '[.action, .failover_secs] | @tsv' ha-soak-*.jsonl \
  | awk '{a[$1]++; s[$1]+=$2} END{for (k in a) printf "%-20s n=%-4d avg=%.1fs\n", k, a[k], s[k]/a[k]}'
```

Common failure modes and what they mean — see the cluster-side
runbook at
[charts/cube-stack-ha/docs/HA-UPGRADE.md](../../charts/cube-stack-ha/docs/HA-UPGRADE.md)
section 5 (Failure modes).

## Notes

- The runner does NOT need to live on the same cluster as the soak
  target. It just needs network reach + a kubeconfig context. A
  cheaper setup: small VM or Docker container on a personal box, with
  kubeconfig copied from your `kubectx` — the `runs-on:
  [self-hosted, cube-soak-runner]` label is the only contract.
- The default schedule (`0 2 * * *`) runs nightly at 02:00 UTC. If
  your runner pool is busier at that time, edit the cron in
  `.github/workflows/ha-soak.yaml`.
- For initial roll-out, start with `workflow_dispatch` smoke runs at
  `duration=600` for a few days before enabling the schedule. Then
  ramp up to `duration=3600` (1h) for nightly.
