package main

# Policy for the rendered Kubernetes manifests (all three overlays).
#
# The cluster's Pod Security Admission would reject most of these at apply time anyway.
# Checking in CI means the failure appears on the pull request -- with a file name and a
# line in the diff -- instead of halfway through a deploy.
#
# Run locally:
#   kubectl kustomize k8s/overlays/eks | conftest test -p platform/policies -

workloads[container] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
}

pod_spec = spec {
  input.kind == "Deployment"
  spec := input.spec.template.spec
}

has_dropped_all(container) {
  container.securityContext.capabilities.drop[_] == "ALL"
}

# --- Pod-level hardening ----------------------------------------------------------------

deny[msg] {
  spec := pod_spec
  not spec.securityContext.runAsNonRoot
  msg := sprintf("%s: pod must set securityContext.runAsNonRoot: true", [input.metadata.name])
}

deny[msg] {
  spec := pod_spec
  spec.securityContext.seccompProfile.type != "RuntimeDefault"
  msg := sprintf("%s: pod must set seccompProfile.type: RuntimeDefault", [input.metadata.name])
}

deny[msg] {
  spec := pod_spec
  spec.automountServiceAccountToken != false
  msg := sprintf("%s: must set automountServiceAccountToken: false unless the workload calls the Kubernetes API", [input.metadata.name])
}

deny[msg] {
  spec := pod_spec
  spec.hostNetwork
  msg := sprintf("%s: hostNetwork is not allowed", [input.metadata.name])
}

deny[msg] {
  spec := pod_spec
  spec.hostPID
  msg := sprintf("%s: hostPID is not allowed", [input.metadata.name])
}

# --- Container-level hardening -----------------------------------------------------------

deny[msg] {
  container := workloads[_]
  container.securityContext.allowPrivilegeEscalation != false
  msg := sprintf("%s/%s: allowPrivilegeEscalation must be false", [input.metadata.name, container.name])
}

deny[msg] {
  container := workloads[_]
  container.securityContext.readOnlyRootFilesystem != true
  msg := sprintf("%s/%s: readOnlyRootFilesystem must be true", [input.metadata.name, container.name])
}

deny[msg] {
  container := workloads[_]
  not has_dropped_all(container)
  msg := sprintf("%s/%s: capabilities.drop must contain ALL", [input.metadata.name, container.name])
}

deny[msg] {
  container := workloads[_]
  container.securityContext.runAsUser < 1
  msg := sprintf("%s/%s: must run as a non-root numeric uid", [input.metadata.name, container.name])
}

# --- Scheduling and reliability -----------------------------------------------------------

deny[msg] {
  container := workloads[_]
  not container.resources.requests.cpu
  msg := sprintf("%s/%s: missing resources.requests.cpu (the HPA has no denominator without it)", [input.metadata.name, container.name])
}

deny[msg] {
  container := workloads[_]
  not container.resources.limits.memory
  msg := sprintf("%s/%s: missing resources.limits.memory", [input.metadata.name, container.name])
}

deny[msg] {
  container := workloads[_]
  not container.livenessProbe
  msg := sprintf("%s/%s: missing livenessProbe", [input.metadata.name, container.name])
}

deny[msg] {
  container := workloads[_]
  not container.readinessProbe
  msg := sprintf("%s/%s: missing readinessProbe", [input.metadata.name, container.name])
}

deny[msg] {
  container := workloads[_]
  endswith(container.image, ":latest")
  msg := sprintf("%s/%s: image must not use the :latest tag", [input.metadata.name, container.name])
}

deny[msg] {
  container := workloads[_]
  not contains(container.image, ":")
  msg := sprintf("%s/%s: image must be pinned to a tag or digest", [input.metadata.name, container.name])
}

# A single replica is not highly available, whatever the probes say.
deny[msg] {
  input.kind == "Deployment"
  input.spec.replicas < 2
  msg := sprintf("%s: replicas must be at least 2", [input.metadata.name])
}

deny[msg] {
  input.kind == "HorizontalPodAutoscaler"
  input.spec.minReplicas < 2
  msg := sprintf("%s: HPA minReplicas must be at least 2", [input.metadata.name])
}

# --- Exposure ---------------------------------------------------------------------------

deny[msg] {
  input.kind == "Service"
  input.spec.type == "NodePort"
  msg := sprintf("%s: NodePort Services are not allowed; use an Ingress", [input.metadata.name])
}

deny[msg] {
  input.kind == "Service"
  input.spec.type == "LoadBalancer"
  msg := sprintf("%s: LoadBalancer Services bypass the Ingress; use ClusterIP", [input.metadata.name])
}

deny[msg] {
  input.kind == "Namespace"
  input.metadata.labels["pod-security.kubernetes.io/enforce"] != "restricted"
  msg := sprintf("%s: namespace must enforce the restricted Pod Security Standard", [input.metadata.name])
}

# --- cert-manager: certificate hygiene ---------------------------------------------------
#
# Rotation is only real when it reaches the process, so these rules check the Certificate
# objects *and* the Pods that consume their Secrets. Conftest evaluates one document at a
# time, so every rule is local to its object rather than following Certificate -> Secret ->
# Deployment; that is a property of the tool, not an oversight.

# Helper rule (no hyphens: Rego identifiers cannot contain them).
is_cert_manager_certificate {
  input.kind == "Certificate"
  input.apiVersion == "cert-manager.io/v1"
}

deny[msg] {
  is_cert_manager_certificate
  not input.spec.secretName
  msg := sprintf("%s: Certificate must set spec.secretName", [input.metadata.name])
}

# Leaves live 30 days and are renewed 10 days out. A longer-lived leaf is what makes a
# stolen one worth keeping, and a shorter one turns renewal into a daily event.
deny[msg] {
  is_cert_manager_certificate
  not input.spec.isCA
  input.spec.duration != "720h"
  msg := sprintf("%s: leaf certificate duration must be 720h (30d)", [input.metadata.name])
}

deny[msg] {
  is_cert_manager_certificate
  not input.spec.isCA
  input.spec.renewBefore != "240h"
  msg := sprintf("%s: leaf certificate renewBefore must be 240h (10d)", [input.metadata.name])
}

# A new private key on every renewal: a leaked key is useful only until the next rotation.
deny[msg] {
  is_cert_manager_certificate
  not input.spec.isCA
  input.spec.privateKey.rotationPolicy != "Always"
  msg := sprintf("%s: leaf certificate must set privateKey.rotationPolicy: Always", [input.metadata.name])
}

# CAs last five years and never rotate their key on a timer: rotating a CA invalidates every
# leaf it signed, which is a planned rollout, not something a controller should start.
deny[msg] {
  is_cert_manager_certificate
  input.spec.isCA
  input.spec.duration != "43800h"
  msg := sprintf("%s: CA certificate duration must be 43800h (5y)", [input.metadata.name])
}

deny[msg] {
  is_cert_manager_certificate
  input.spec.isCA
  input.spec.privateKey.rotationPolicy != "Never"
  msg := sprintf("%s: CA certificate must set privateKey.rotationPolicy: Never", [input.metadata.name])
}

# A Secret that is renewed on disk only takes effect when the process re-reads it at
# startup. Without a reloader the certificate silently expires in memory while the cluster
# reports every Certificate as Ready.
deny[msg] {
  input.kind == "Deployment"
  input.spec.template.spec.volumes[_].secret.secretName
  not input.spec.template.metadata.annotations["reloader.stakater.com/auto"]
  msg := sprintf("%s: mounts a Secret volume but does not set reloader.stakater.com/auto; a renewed certificate would never reach the process", [input.metadata.name])
}
