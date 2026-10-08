# VM requirements (Vercel + GitHub Actions setup)

- **Public IPv4**, region `ap-mumbai-1` (Vercel functions will move to region `bom1`).
- **Security List ingress** on the subnet: TCP 22 (SSH) and TCP 5432 (Postgres).
  Vercel has no fixed egress IPs, so 5432 must allow `0.0.0.0/0` - use a strong password and SSL.
- **Postgres reachable with SSL**, so `DATABASE_URL` can use `?sslmode=require`.
- **Env vars to update later:** `DATABASE_URL` in Vercel and in GitHub Actions secrets.

Not part of VM creation: Postgres install and app changes come later. The Ubuntu image also ships
iptables rules, so the OS firewall must allow 22 and 5432 once Postgres is installed.
