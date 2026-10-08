# oracle-getVM

Retries creating an Oracle Cloud Always Free VM (`jobfeed-db`: A1.Flex, 2 OCPU, 12 GB, Ubuntu 24.04 aarch64, 100 GB boot @ 10 VPU, ap-mumbai-1) until capacity frees up.

- Script: `infra/oracle-get-vm.sh` (OCI CLI, config from env vars only)
- Workflow: `.github/workflows/oracle-get-vm.yml` (manual + every 10 min; ~5 attempts x 20 s per run)
- VM needs: `infra/VM-REQUIREMENTS.md`

If `jobfeed-db` is already RUNNING/PROVISIONING the script prints its IP and exits 0 immediately.
If there is no capacity after all attempts it also exits 0 (so you don't get a failure email every run); real errors exit 1.

## Run locally
Install the OCI CLI, copy `.env.example` to `.env`, fill it in, then:

    set -a; source .env; set +a; bash infra/oracle-get-vm.sh

Tune with `MAX_ATTEMPTS` (default 5) and `RETRY_INTERVAL` seconds (default 20).

## GitHub Actions
Add these repo secrets (Settings > Secrets and variables > Actions): `OCI_TENANCY_OCID`, `OCI_USER_OCID`, `OCI_FINGERPRINT`, `OCI_PRIVATE_KEY`, `OCI_REGION`, `OCI_COMPARTMENT_OCID`, `OCI_SUBNET_OCID`, `SSH_PUBLIC_KEY`.

### How it stops
When the VM exists, the script writes `vm-created.json` (name, shape, size, region, timestamp - no OCIDs, IP or keys). The workflow commits it, then disables itself. Any run that still starts sees the file and skips everything. To resume hunting (e.g. after deleting the VM), delete `vm-created.json` from the repo and re-enable the workflow.

Running locally also writes `vm-created.json` in the current directory; commit and push it if you want the workflow to stop.

> This repo is public, so run logs - including the VM's public IP - are public until the workflow stops.
> GitHub also auto-disables schedules after 60 days without repo activity.
> The workflow needs Settings > Actions > General > Workflow permissions to allow write access (or the `permissions:` block in the YAML, which is already set).

## Where to get the values
- **Tenancy OCID / Region:** Console > profile menu > Tenancy.
- **User OCID, API key, fingerprint, private key:** profile menu > My profile > API keys > Add API key > Generate, download the private key, copy the fingerprint shown in the config preview. `OCI_PRIVATE_KEY` is the full PEM file contents.
- **Compartment OCID:** Identity > Compartments (root compartment = tenancy OCID).
- **Subnet OCID:** Networking > Virtual cloud networks > your VCN > Subnets > the public subnet.
- **SSH_PUBLIC_KEY:** contents of your `.pub` file (`ssh-keygen -t ed25519` if you have none).
