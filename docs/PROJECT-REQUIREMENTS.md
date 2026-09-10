# What a project has to provide

Meet these and the shared pipeline can deploy it. Five of the six are about the
application rather than the infrastructure, and on an existing project those
five are where the real work is.

## 1. Configuration from the environment only

No committed config file, no hardcoded hosts, no `if (env === 'production')`
branches choosing a database. This is usually the largest piece of work on a
project that has not been deployed this way before.

## 2. A `/health` endpoint that means something

It should answer only when the application can actually do its job — reach its
database, reach whatever else it cannot work without. The pipeline's rollback
depends on the answer, so an endpoint that returns 200 as long as the process is
alive is worse than no endpoint: it turns a failed deploy into a green one.

The dialer's returns 503 when its event socket is down as well as when its
database is, which is the shape to copy.

## 3. Logs to stdout and stderr

No log files on disk. The platform collects what the process prints.

## 4. Listens on `$PORT`

Not a hardcoded port.

## 5. No local disk state

Or exactly one declared volume, named and understood. A container that writes
somewhere no one declared loses that data at the next deploy, quietly.

## 6. A two-stage Dockerfile, running as a non-root user

For the ECS lane only. Two stages so the image does not carry the toolchain that
built it; non-root because the task role is not the only thing standing between
a compromised process and the rest of the account.

---

## What the platform provides in return

- ECR repository and lifecycle policy
- ECS service, task definition, log group
- Secrets in SSM Parameter Store, injected as environment variables
- A database and user on the shared RDS instance, if wanted
- API Gateway route and certificate for a custom domain
- Deploy, health check and rollback

## Registering a project

In the calling repository, set:

**Secrets**

| | |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | the role for the account being deployed to |

For the SSM lane, also `ARTIFACT_BUCKET` and `INSTANCE_ID`.

**Nothing else.** Cluster, service, repository and family are inputs in the
project's `cd.yml`, in the open, where they can be read without opening
settings.
