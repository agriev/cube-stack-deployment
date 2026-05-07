# Inter-node TLS for Raft (cube-stack-ha) — design + status

**Status:** chart-side scaffold landed (PR-T2 in this repo); upstream
Rust impl deferred. Operators who set `cubestore.tls.enabled: true`
hit a `_validations.tpl` fail-fast until both sides ship.

## Why

The Cube Store HA fork's Raft transport is plain TCP. The frame
header (`FRAME_MAGIC` 0xC8EA_AF01 + `FRAME_VERSION` 1 + length prefix)
provides minimal integrity but no authentication and no encryption. On
a same-zone k8s cluster with deny-all NetworkPolicy and namespace
isolation that's acceptable. **It is not** for cross-zone, hybrid-
cloud, or shared-tenant clusters where Raft traffic might cross an
untrusted hop.

PR-T2 promotes inter-node TLS to "required for on-prem prod
deployments that span more than one zone". This design doc captures
what the chart and the Rust transport layer need to agree on.

## Wire model

Two paths to encrypt:

1. **router → router** (Raft consensus). Listener on
   `cubestore.metaPort` (default 9007).
2. **worker → router** (DML traffic + heartbeat). Listener on
   `cubestore.metaPort` again, but with the worker as client.

Single TLS context, both directions. Server cert and client cert can
be the same — every cubestored process is both. mTLS (`clientAuth:
require`) is the recommended mode: it makes the trust boundary "any
peer holding a CA-signed cert" rather than "any IP that can reach the
listener".

## Cert SAN list

`cert-manager` Certificate object should request:

```yaml
spec:
  dnsNames:
    # Headless service (router-to-router peer discovery)
    - "{{ .release }}-cubestore-router-headless.{{ .namespace }}.svc.cluster.local"
    - "{{ .release }}-cubestore-router-headless.{{ .namespace }}"
    # Per-pod FQDNs (each replica)
    - "{{ .release }}-cubestore-router-0.{{ ... }}"
    - "{{ .release }}-cubestore-router-1.{{ ... }}"
    - "{{ .release }}-cubestore-router-2.{{ ... }}"
    # ClusterIP service (worker-to-router client traffic)
    - "{{ .release }}-cubestore-router.{{ .namespace }}.svc.cluster.local"
```

Workers don't strictly need their own cert (they're clients only) but
mTLS auth requires them to present one signed by the same CA.

## Stage 1 — Rust impl (agriev/cube fork)

New module: `rust/cubestore/cubestore/src/raft/tls.rs`. Provides
`TlsTcpTransport` that wraps `tokio_rustls::server::TlsStream` /
`TlsConnector`. Trait-compatible with the existing `Transport`.

`raft/transport.rs` becomes a factory:

```rust
pub async fn build_transport(opts: TransportOpts) -> Arc<dyn Transport> {
    if opts.tls_enabled {
        Arc::new(TlsTcpTransport::new(opts).await?)
    } else {
        Arc::new(TcpTransport::new(opts).await?)
    }
}
```

Env vars (all read once at startup):

| Var                                  | Required when TLS on | Notes                              |
| ------------------------------------ | -------------------- | ---------------------------------- |
| `CUBESTORE_RAFT_TLS_ENABLED`         | n/a (the toggle)     | "true" → TLS path                  |
| `CUBESTORE_RAFT_TLS_CERT_FILE`       | yes                  | PEM, RSA or ECDSA                  |
| `CUBESTORE_RAFT_TLS_KEY_FILE`        | yes                  | PEM, unencrypted                   |
| `CUBESTORE_RAFT_TLS_CA_FILE`         | yes (mTLS)           | Bundle pinning peer trust         |
| `CUBESTORE_RAFT_TLS_CLIENT_AUTH`     | optional             | none / optional / require          |

Cargo.toml additions: `tokio-rustls = "0.26"`, `rustls-pemfile = "2"`.
The chart's `_validations.tpl` blocks `tls.enabled: true` until the
operator opts in via `tls.acknowledgeImageTag: true` because earlier
images silently ignore the env vars and continue plain TCP — failing
loud beats a silent downgrade.

Tag a new image: `cubejs/cubestore-ha:v0.2.0`.

## Stage 2 — chart (this repo, current PR)

`templates/cubestore/_tls-helpers.tpl` (new) — three helpers:

- `cubeStack.cubestore.tls.envVars` — `CUBESTORE_RAFT_TLS_*` env block.
- `cubeStack.cubestore.tls.volumeMounts` — `/etc/cubestore/tls`
  read-only mount.
- `cubeStack.cubestore.tls.volumes` — `secret` volume from
  `existingSecret`.

Router and worker StatefulSets call these helpers (deferred to a
follow-up commit — current PR-T2 lands the helpers + values shape +
fail-fast only).

`values.yaml` adds:

```yaml
cubestore:
  tls:
    enabled: false
    existingSecret: ""
    clientAuth: require            # none | optional | require
    acknowledgeImageTag: false
```

`_validations.tpl` enforces:

- `tls.enabled: true` ⇒ `existingSecret` is non-empty.
- `tls.enabled: true` ⇒ `acknowledgeImageTag: true`.
- `clientAuth` is one of `none / optional / require`.

## Test path

```bash
# Generate a self-signed CA + leaf cert via cert-manager local Issuer
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: { name: cube-ha-ca, namespace: cube-ha }
spec: { selfSigned: {} }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: cube-ha-router-tls, namespace: cube-ha }
spec:
  secretName: cube-ha-router-tls
  duration: 720h
  issuerRef: { name: cube-ha-ca, kind: Issuer }
  dnsNames: [ ... per the SAN list above ... ]
EOF

# Install with TLS on
helm install cube-ha charts/cube-stack-ha \
  -f charts/cube-stack-ha/values.yaml \
  -f charts/cube-stack-ha/values-prod.yaml \
  --set cubestore.tls.enabled=true \
  --set cubestore.tls.existingSecret=cube-ha-router-tls \
  --set cubestore.tls.acknowledgeImageTag=true \
  --set cubestoreImage.tag=v0.2.0      # required

# Smoke-test
make ha-verify TLS=on
```

`scripts/ha-verify.sh` extension (deferred): when `TLS=on`, the
verify step checks TCP port 9007 with `openssl s_client -connect ...`
and confirms the cert chain pins the local CA before running the
existing election + failover assertions.

## Out of scope

- Rotation. Cert-manager handles rotation; the cube process needs a
  `SIGHUP`-style reload to pick up new certs without restart. v0.2
  keeps it simple: rolling restart on cert change. Configurable via
  `kubectl rollout restart`.
- Cipher suite tuning. Defaults from rustls (TLS 1.3 only) are
  appropriate for inter-node traffic; no operator-tunable cipher
  list.
- Public CA / Let's Encrypt. The intra-cluster cert chain stays
  internal — no point trusting public CAs for inter-node Raft.
