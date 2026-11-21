# Runbook: rotating the JWT signing key

## What the key is

`auth` signs access and refresh tokens with an RS256 key pair. `catalog` and `gateway` only
ever hold the **public** half and verify with it, so the private key exists in exactly one
service.

| Where | Private | Public |
|---|---|---|
| AWS | Secrets Manager JSON: `private_key` | same secret, `public_key` |
| Azure | Key Vault `jwt-private` | Key Vault `jwt-public` |
| GCP | Secret Manager `jwt-private-key` | Secret Manager `jwt-public-key` |
| Kubernetes | `auth-secrets` → `jwt-private-key` | `auth-secrets` → `jwt-public-key` |
| Local | `.keys/jwt-private.pem` | `.keys/jwt-public.pem` |

The services read the pair at start-up: `apps/common/config.py` accepts either the PEM in an
environment variable (`JWT_PRIVATE_KEY`) or a path (`JWT_PRIVATE_KEY_PATH`). Nothing reads
the key again after boot, which is the single most important fact for this runbook: **the
new key takes effect when the process restarts, not when the secret changes.**

## What a rotation actually costs

There is one key and no `kid`, so a new key pair means every token signed with the old one
stops verifying. The window is bounded by the token lifetime:

* access tokens: `ACCESS_TOKEN_TTL_SECONDS`, default **900 s**
* refresh tokens: `REFRESH_TOKEN_TTL_SECONDS`, default **604800 s**

A refresh token signed with the old key cannot be exchanged, so clients must log in again.
In practice a rotation is a **forced re-login for every active session**, not a transparent
swap. Plan it accordingly, and say so in the change record rather than discovering it.

The zero-downtime version — publish both public keys, verify against either, sign with the
new one, then drop the old one — needs a `kid` header and a JWKS endpoint that the services
do not have yet. That is a Phase 5 change, not something to improvise during an incident.
If a rotation is happening because the key leaked, take the forced re-login.

## Procedure

### 1. Generate and stage the new pair

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out jwt-private.pem
openssl rsa -in jwt-private.pem -pubout -out jwt-public.pem
```

Keep the old pair until the rotation is confirmed: it is the rollback.

### 2. Write the new material to the provider

**AWS** — one JSON secret, both keys:

```bash
aws secretsmanager put-secret-value \
  --secret-id "$(terraform -chdir=infra/envs/aws/dev output -raw jwt_secret_arn)" \
  --secret-string "$(jq -n --rawfile p jwt-private.pem --rawfile u jwt-public.pem \
    '{private_key: $p, public_key: $u}')"

aws ecs update-service --cluster showcase-dev --service showcase-dev-auth \
  --force-new-deployment
```

`--force-new-deployment` is required: the secret is resolved by the execution role at task
start, so nothing changes until a new task starts.

**Azure** — two secrets, then a new revision:

```bash
az keyvault secret set --vault-name showcase-dev-kv --name jwt-private --file jwt-private.pem
az keyvault secret set --vault-name showcase-dev-kv --name jwt-public  --file jwt-public.pem

az containerapp revision restart -g rg-showcase-dev -n showcase-dev-auth
```

**GCP** — a new version, then a revision:

```bash
gcloud secrets versions add jwt-private-key --data-file=jwt-private.pem
gcloud secrets versions add jwt-public-key  --data-file=jwt-public.pem

# Cloud Run pins `latest`, so any update that creates a revision picks the new version up.
gcloud run services update auth --region europe-west1 \
  --update-env-vars "JWT_ROTATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

**Kubernetes** — the external-secrets operator syncs the Secret, but pods keep the old value
until they restart:

```bash
kubectl -n showcase rollout restart deploy/auth deploy/catalog deploy/gateway
kubectl -n showcase rollout status deploy/auth --timeout=180s
```

**Local**:

```bash
rm -rf .keys && make keys && make restart
```

### 3. Verify

```bash
make smoke LOCAL_URL=https://<entrypoint>          # register, login, CRUD, refresh
k6 run scripts/loadtest.k6.js                      # thresholds fail on a broken verify path
```

Then confirm the old tokens are actually refused — a rotation that silently accepts the old
key is worse than none, because it hides that the secret was not picked up:

```bash
curl -s -o /dev/null -w '%{http_code}\n' "$URL/auth/me" -H "Authorization: Bearer $OLD_TOKEN"
# expect 401
```

### 4. Roll back

Re-write the previous secret version and restart again:

```bash
aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
  --version-stage AWSPREVIOUS --query SecretString --output text   # AWS
az keyvault secret show --vault-name showcase-dev-kv --name jwt-private \
  --version <previous-version>                                     # Azure
gcloud secrets versions access <previous-version> --secret jwt-private-key  # GCP
```

Then repeat step 2 with that material. Rollback is the same operation as rotation, which is
why the old pair is kept until step 3 passes.

## Cadence and triggers

| Trigger | Action |
|---|---|
| Scheduled | Every 90 days, in a low-traffic window |
| Suspected leak | Immediately, and treat all sessions as compromised |
| Staff departure with secret access | Immediately |
| Provider rotation policy | Follow the policy; the procedure is identical |

## Known gaps

* No `kid` and no JWKS: verification uses a single key, so there is no overlap window.
* No automated rotation: this is a runbook, deliberately. Automating a forced re-login
  without an overlap mechanism would turn a scheduled job into a scheduled outage.
