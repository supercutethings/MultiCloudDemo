# Policy as code

`conftest test plan.json -p platform/policies` runs these rules against the JSON plan in CI,
before anything is applied. A violation fails the pipeline.

| Rule | Why |
|---|---|
| No ingress from `0.0.0.0/0` except 80/443 | The one mistake that turns a demo VPC into an open proxy |
| RDS storage must be encrypted | Encryption cannot be enabled later without a snapshot dance |
| RDS must not be publicly accessible | The database should never have a route from the internet |
| Leaves are 30 days, renewed 10 days out, `rotationPolicy: Always` | A long-lived leaf is what makes a stolen one worth keeping |
| CA certificates are 5 years with `rotationPolicy: Never` | Rotating a CA invalidates every leaf it signed — a planned rollout, not a timer |
| Every `Certificate` sets `secretName` | A Certificate with nowhere to write is a silent no-op |
| A Deployment mounting a Secret volume must enable Reloader | Otherwise a renewed certificate never reaches the process, and the cluster still reports `Ready` |

These are intentionally few and precise. Rules that duplicate `terraform validate` or
`tflint` add noise without adding safety.
