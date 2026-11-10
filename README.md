# service-discovery

Netflix Eureka service registry for the JavaMS platform (component C-04).
Spring Boot 4.0.9, Spring Cloud 2025.1.4, Java 21.

The registry every other service registers with. It carries no business logic
and no datasource — it never touches `ecommerce_platform_db`, which is why it is
the one service that can be extracted from the platform monorepo and run on its
own.

Extracted from the `platform-parent` reactor, so `pom.xml` now inherits from
`spring-boot-starter-parent` directly and restates the three things the parent
actually contributed: the Spring Cloud BOM, Java 21, and
`spring-boot-starter-test`. **Spring Boot 4.0.9 and Spring Cloud 2025.1.4 are
locked together** — raising one without the other breaks the build.

## Endpoints

| Path | What it is |
|---|---|
| `/` | Eureka dashboard (HTML) |
| `/eureka/apps` | Registry API — what clients read and write |
| `/actuator/health` | Overall health, with `liveness` and `readiness` groups |
| `/actuator/prometheus` | Metrics for scraping |

## Run it locally

```bash
mvn -B verify                 # build and test
mvn spring-boot:run           # http://localhost:8761
```

As a container — `mvn package` first, since the `Dockerfile` only packages the
jar and does not compile:

```bash
mvn -B package
docker build -t service-discovery:dev .
docker run --rm -p 8761:8761 -e EUREKA_HOSTNAME=localhost service-discovery:dev
```

### Configuration

| Variable | Default | Notes |
|---|---|---|
| `SERVER_PORT` | `8761` | |
| `EUREKA_HOSTNAME` | `localhost` | The registry builds its own `defaultZone` from this, so in a cluster it must be the Service name other pods resolve — `service-discovery`. |
| `EUREKA_SELF_PRESERVATION` | `false` | Off locally so a stopped service is evicted promptly. **On in Kubernetes** (`k8s/deployment.yaml` sets it), because pods churn faster than the registry would otherwise tolerate. |

## Deploy to GKE

```bash
kubectl apply -k k8s
```

That applies the namespace, the ClusterIP Service, the registry Deployment and
the ngrok tunnel. The `ngrok-credentials` Secret is **not** in the kustomization
— it holds a real authtoken, so it is created out of band (below) rather than
committed.

Notes on the manifests:

- **Single replica, and it must stay that way.** `application.yml` runs
  standalone (`register-with-eureka` and `fetch-registry` both false), so a
  second replica would be an independent, empty registry rather than a peer,
  and clients would see a different view depending on which pod the Service
  picked.
- **`readOnlyRootFilesystem: true` with a writable `/tmp` emptyDir.** Embedded
  Tomcat must create a work directory under `java.io.tmpdir` before it can bind
  a port; without that volume startup fails with
  `Unable to create tempDir. java.io.tmpdir is set to /tmp`.
- **No NodePort.** The monorepo exposed 30761 for local clusters. On GKE that
  would mean a firewall rule to node IPs; public access is the tunnel's job.

## The ngrok tunnel

An ngrok agent runs in the cluster and forwards to `service-discovery:8761`, so
the registry gets a public `https` URL with no LoadBalancer, no Ingress
controller, no public IP and no firewall rule.

It is a **separate Deployment, not a sidecar**: the registry is a single replica,
and a sidecar would tie the tunnel to its lifecycle, so every registry rollout
would drop the tunnel and — without a reserved domain — change the public URL.

### Setup

1. Sign up at [ngrok.com](https://ngrok.com) and copy your authtoken from
   [the dashboard](https://dashboard.ngrok.com/get-started/your-authtoken).
2. Claim your **static domain** (Domains → it is free, one per account). This is
   worth doing: without it ngrok assigns a random URL that changes on every
   tunnel pod restart.
3. Store both as repository configuration (below). The pipeline builds the
   Secret from them on each deploy.

To create the Secret by hand instead:

```bash
kubectl -n javams create secret generic ngrok-credentials \
  --from-literal=authtoken='<your authtoken>' \
  --from-literal=domain='<your-domain>.ngrok-free.app'
```

The `domain` key is optional; omit it for an ephemeral URL.

### ⚠ This exposes the registry to the internet

Anyone with the URL can read every registered instance's host and port, and
`/eureka/*` **accepts writes** — a stranger can register or de-register
instances. Mitigations, most effective first:

```bash
# 1. Turn the tunnel off when you are not using it.
kubectl -n javams scale deploy/ngrok-tunnel --replicas=0
```

2. Put an ngrok traffic policy in a ConfigMap named `ngrok-traffic-policy`. The
   Deployment mounts it optionally and adds `--traffic-policy-file` only when it
   exists, so creating it and restarting the tunnel is the whole change:

   ```bash
   cat > policy.yml <<'EOF'
   on_http_request:
     - actions:
         - type: basic-auth
           config:
             credentials:
               - "admin:<a long random password>"
   EOF
   kubectl -n javams create configmap ngrok-traffic-policy --from-file=policy.yml
   kubectl -n javams rollout restart deploy/ngrok-tunnel
   ```

   The agent validates only the *syntax* of a policy file locally — action names
   and their config are checked server-side when the tunnel starts. Confirm the
   tunnel came up after applying one: `kubectl -n javams logs deploy/ngrok-tunnel`.

Note on agent flags: `--host-header` and `--basic-auth` **do not exist** on
agent 3.x (they were removed after v2). Host rewriting is not needed here —
Eureka's dashboard uses relative links and `/eureka/*` is Host-agnostic — and
auth is now a traffic policy action, which is what the mount above is for.

## CI/CD

[.github/workflows/ci-cd.yml](.github/workflows/ci-cd.yml) — build → test →
image → publish → deploy.

| Event | build | test | image | publish | deploy |
|---|---|---|---|---|---|
| Pull request to `main` | yes | yes | yes | no | no |
| Push to `main` | yes | yes | yes | yes | yes |
| Tag `v*` | yes | yes | yes | yes | yes |
| Manual | yes | yes | yes | yes | unless `skip_deploy` |

`build` and `test` run in parallel rather than in sequence: a job cannot inherit
another's `target/`, so both compile once, but the wall clock is `max()` instead
of the sum and the shared `~/.m2` cache means neither re-downloads dependencies.

The `image` stage starts the registry for real and waits for
`/actuator/health` to report `UP`, under `--read-only --tmpfs /tmp` — the same
security context the Deployment uses. Because the registry has no dependencies,
this genuinely exercises it in CI, so a broken context surfaces there rather
than as a `CrashLoopBackOff` after deploy.

The `deploy` stage applies the manifests, waits for both rollouts, resolves the
public URL (from the reserved domain if set, otherwise parsed from the agent
log) and then probes `<url>/actuator/health` through the tunnel — proving the
whole path, not just that the pods are `Running`. The URL is written to the run
summary. On failure it rolls both Deployments back and dumps pods, events and
logs.

Images are tagged `sha-<12 chars of commit>`, plus `latest` on `main` and semver
on a `v*` tag. The cluster always runs the immutable sha tag, which is what
makes `imagePullPolicy: IfNotPresent` safe.

### Required repository configuration

Settings → Secrets and variables → Actions.

| Kind | Name | Value |
|---|---|---|
| Secret | `DOCKERHUB_USERNAME` | Docker Hub account |
| Secret | `DOCKERHUB_TOKEN` | Docker Hub access token, **Read & Write** scope — not the password |
| Secret | `NGROK_AUTHTOKEN` | from the ngrok dashboard |
| Secret | `GCP_WIF_PROVIDER` | `projects/<number>/locations/global/workloadIdentityPools/github/providers/github` |
| Secret | `GCP_SERVICE_ACCOUNT` | `github-deployer@<project>.iam.gserviceaccount.com` |
| Variable | `GCP_PROJECT_ID` | the GCP project id |
| Variable | `GKE_CLUSTER` | cluster name |
| Variable | `GKE_LOCATION` | region for a regional cluster, zone for a zonal one |
| Variable | `NGROK_DOMAIN` | your static ngrok domain. Optional, strongly recommended |
| Variable | `DOCKERHUB_NAMESPACE` | optional; defaults to `DOCKERHUB_USERNAME` |

You also need a GitHub environment named `production` (Settings →
Environments) if you want reviewers or a branch rule on deploys; the job runs
without one, just unguarded.

### GCP: keyless auth via Workload Identity Federation

The workflow holds no service account key — the deploy job has
`id-token: write` and mints a short-lived token. Run once:

```bash
PROJECT_ID=<your project id>
REPO=<owner>/service-discovery
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')

gcloud iam service-accounts create github-deployer \
  --project="$PROJECT_ID" --display-name="GitHub Actions deployer"
SA="github-deployer@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA}" --role="roles/container.developer"

gcloud iam workload-identity-pools create github \
  --project="$PROJECT_ID" --location=global --display-name="GitHub"

gcloud iam workload-identity-pools providers create-oidc github \
  --project="$PROJECT_ID" --location=global --workload-identity-pool=github \
  --display-name="GitHub OIDC" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository == '${REPO}'"

# Only this repository may impersonate the service account. Without the
# attribute condition above and this specific member, any GitHub repo could.
gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --project="$PROJECT_ID" --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/${REPO}"

echo "GCP_WIF_PROVIDER = projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/providers/github"
echo "GCP_SERVICE_ACCOUNT = ${SA}"
```

### If the Docker Hub repository is private

GKE cannot pull it without credentials. Either make the repository public, or
add an image pull secret:

```bash
kubectl -n javams create secret docker-registry dockerhub \
  --docker-username='<user>' --docker-password='<access token>'
kubectl -n javams patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"dockerhub"}]}'
```

## Relationship to the monorepo

This is an extraction of the `service-discovery` module from the JavaMS
platform. Keeping both means the usual duplication risk: `application.yml` and
the Java source exist in two places. If the platform keeps its own copy, decide
which repository is authoritative — running both against one cluster namespace
will have them fight over the same Deployment.
