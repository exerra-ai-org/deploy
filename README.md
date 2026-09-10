# deploy

Reusable GitHub Actions workflows that ship Exerra projects to AWS.

A project's own `cd.yml` should be about ten lines. Everything that is the same
for every project lives here, once, so that fixing it once fixes it everywhere.

This repository is public on purpose. It contains no secrets — those stay in the
calling repository and arrive through `secrets: inherit` — and a public
repository can be called by any repository on any GitHub plan, with no Actions
access policy to configure.

## The two lanes

| | `ecs.yml` | `ssm-release.yml` |
|---|---|---|
| For | containerised backends | a machine that cannot be a container |
| Ships | an image to ECR, then a new task definition revision | a build artefact to S3, then over SSM |
| Used by | most projects | the dialer |

Both share the same four properties:

1. **Build once, deploy that artefact.** Rebuilding at deploy time ships
   something nobody tested.
2. **The runner never touches a server.** GitHub assumes a short-lived role
   through OIDC. No AWS key is stored anywhere and port 22 stays shut.
3. **The trigger is the project's choice.** Push-to-branch where a deploy is
   cheap; `workflow_dispatch` with a typed confirmation where it is not.
4. **Health check, then roll back.** The whole team deploys. Someone
   unfamiliar will run it eventually.

## Using the ECS lane

```yaml
name: CD
on:
  push:
    branches: [main]

jobs:
  deploy:
    uses: exerra-ai-org/deploy/.github/workflows/ecs.yml@v1
    with:
      project: acrm
      cluster: agency-prod
      service: acrm-service
      ecr-repository: acrm
      task-family: acrm
      health-url: https://api.acrm.example.com/health
    secrets: inherit
```

More in [`examples/`](./examples).

## What this fixes

The previous arrangement copied `deploy-ecs.yml` into each repository. Three
things were wrong with it, and the third is the one that matters.

**It drifted.** Fourteen repositories, fourteen copies, no way to fix them
together.

**It reported success it had not earned.** `update-service
--force-new-deployment` returns as soon as the API accepts the call. A task that
crash-looped still produced a green tick.

**It did not deploy the application.** The workflow pushed
`<repo>:<sha>` to ECR and then called `--force-new-deployment`, which re-runs
whichever task definition revision the service already has. The Terraform that
creates a service sets

```hcl
image = "nginx:alpine"
```

as a placeholder and then `ignore_changes = [task_definition]`, so nothing was
ever going to point the service at the image that had just been built. Deploys
pushed images that nothing ran. `ecs.yml` registers a new revision with the new
image, which is the step that was missing.

## Versioning

Call these by tag, not by branch:

```yaml
uses: exerra-ai-org/deploy/.github/workflows/ecs.yml@v1
```

`@main` means a change here can break every project at once, at a moment nobody
chose. `v1` moves deliberately.

## What a project has to provide

See [`docs/PROJECT-REQUIREMENTS.md`](./docs/PROJECT-REQUIREMENTS.md). Six
things, five of which are about the application rather than the infrastructure,
and those five are where the real work is on an existing project.

## Repository separation

A repository can only deploy itself. The app is **derived from
`github.repository`** through a registry inside the workflow, never taken as an
input:

```
exerra-ai-org/dialer  ->  dialer
exerra-ai-org/ACRM    ->  acrm
anything else         ->  refused
```

Everything that decides what gets touched follows from that name:

| | derived as |
|---|---|
| S3 key | `s3://<bucket>/<app>/releases/<app>-<sha>.tar.gz` |
| SSM target | instances tagged `DeployGroup=<group>` **and** `App=<app>` |
| ECR repository | `<namespace>/<app>` |
| ECS service | `<app>-service` |
| Task family, container | `<app>` |

So a caller cannot address another app's prefix, image or service by passing a
different value, because there is no value to pass. Adding an app means editing
the registry in this repository, whose `main` branch requires a review — the
same gate as the workflow itself.

Instances are targeted **by tag rather than by id** for the same reason: an
instance id is guessable and was previously an input. Tagging also makes the
zero-match case explicit — `SendCommand` succeeds against nothing at all and
reports Success, so the workflow checks that at least one invocation exists and
fails loudly if not.

### What this does and does not buy

It is enforced by the **workflow**, not by IAM. With one deploy role shared
across the organisation, IAM sees one principal and cannot tell which repository
is using it — so the prefix separation holds exactly as long as the only path to
that role is this workflow. Two things keep it that way:

- the role's trust policy pins `job_workflow_ref` to this file, so a repository
  cannot write its own workflow and assume the role directly, and
- `main` here requires a review.

That is a real boundary, but it is a different one from IAM. **Graduate to a
role per app** when a repository handles something the others should not reach,
when someone outside the core team gets push access, or when the first
production-touching repository appears. In Terraform that is a `for_each` over
the app list; the caller's workflow does not change.

## Known gap: the IAM trust is org-wide

The roles these workflows assume are created in `aws-agency-infra`, and their
trust policies read:

```
repo:exerra-ai-org/*:ref:refs/heads/main
```

Any repository in the organisation can assume the production deploy role. The
attached policy scopes ECR to all repositories and leaves `iam:PassRole` at
`*`. So write access to the smallest repository is write access to every
project's ECR and every project's service.

`agency-platform.md` states the intended design — one role per project, no role
able to reach another project's anything — and this is not that. It is a
Terraform change in `aws-agency-infra`, not a change here, and it should be made
before more projects are onboarded rather than after.
