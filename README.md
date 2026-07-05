# Jenkins on AWS with Terraform

Single-instance Jenkins CI server deployed on AWS using Terraform — a custom VPC, public subnet, security group, and an EC2 instance running Jenkins, fronted by an Elastic IP.

## Architecture

![Terraform resource graph](images/terraform-graph.png)

**Flow:** `aws_vpc.main` → Internet Gateway → Route Table (0.0.0.0/0 → IGW) → Public Subnet → EC2 instance (Jenkins) → Elastic IP (static public address).

| Resource | Purpose |
|---|---|
| `aws_vpc.main` | Isolated network for the project |
| `aws_internet_gateway.main-gw` | Gives the VPC internet access |
| `aws_route_table.main-rt` + association | Routes public subnet traffic to the IGW |
| `aws_subnet.main-public` | Public subnet hosting the instance |
| `aws_security_group.main_sg` | Allows inbound SSH (22) and Jenkins UI (8080) |
| `data.aws_ami.ami` | Resolves the Amazon Linux 2023 AMI |
| `aws_key_pair.me-key` | SSH key pair for instance access |
| `aws_instance.jenkins` | EC2 instance running Jenkins (installed via `user_data`) |
| `aws_eip.lb` + `aws_eip_association.eip_assoc` | Static public IP attached to the instance |

## Prerequisites

- Terraform >= 1.x
- AWS CLI configured with a named profile (`~/.aws/credentials`)
- An SSH key pair at `~/.ssh/id_rsa` / `~/.ssh/id_rsa.pub`
- AWS account with permissions to create VPC, EC2, and IAM-adjacent networking resources

## Usage

```bash
terraform init
terraform plan
terraform apply
```

Get the public IP once applied:

```bash
terraform output jenkins_public_ip
```

SSH into the instance:

```bash
ssh -i ~/.ssh/id_rsa ec2-user@<eip>
```

Retrieve the Jenkins initial admin password:

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Then open `http://<eip>:8080` in a browser, paste the password, and complete the setup wizard (Install suggested plugins → create admin user).

## `user_data` bootstrap script

```bash
#!/bin/bash
set -e
yum update -y
yum install -y java-21-amazon-corretto
curl -L -o /etc/yum.repos.d/jenkins.repo \
https://pkg.jenkins.io/redhat-stable/jenkins.repo
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
yum install -y jenkins
systemctl enable jenkins
systemctl start jenkins
```

## Issues found and fixed during deployment

Deploying this surfaced a chain of real, non-obvious bugs — documented here since debugging them was most of the actual learning:

1. **Wrong security group attribute.** `security_groups` expects EC2-Classic security group *names*; using a resource reference silently breaks instance creation. Fixed with `vpc_security_group_ids = [aws_security_group.main_sg.id]`.
2. **Private key leaked into `key_name`.** `key_name = file("~/.ssh/id_rsa")` was reading the *private* key instead of referencing the key pair resource. Fixed with `key_name = aws_key_pair.me-key.key_name`.
3. **Broken egress rule.** `protocol = "tcp"` with `from_port/to_port = 0` only allowed TCP port 0 outbound — effectively no internet access. Fixed with `protocol = "-1"` (all protocols) and explicit `cidr_blocks`.
4. **`wget` not installed on Amazon Linux 2023.** AL2023 ships `curl` by default, not `wget`, so the original bootstrap script failed at the Jenkins repo download step. Switched entirely to `curl`.
5. **Redirect not followed.** `pkg.jenkins.io` returns a `301 Moved Permanently`; without `curl -L`, the repo file saved was an HTML redirect page instead of the actual `.repo` file, causing `yum`/`dnf` to report "No match for argument: jenkins".
6. **Java version mismatch.** Jenkins 2.5xx requires Java 21+; `java-17-amazon-corretto` caused `jenkins.service` to crash-loop with `UnsupportedClassVersionError`-style failure on startup. Fixed by installing `java-21-amazon-corretto`.
7. **Missing `subnet_id` on the instance.** Without explicitly setting it, the instance could launch into the wrong (default VPC) subnet instead of the custom public subnet.

### Debugging techniques used

- `cat /var/log/cloud-init-output.log` — surfaces the exact command and error from `user_data` execution.
- `sudo -u jenkins /usr/bin/jenkins` — runs Jenkins in the foreground, bypassing systemd's restart loop, to see the real startup exception instead of a generic "exit-code" failure.
- `journalctl -xeu jenkins.service` — systemd-level service history.
- `curl -I http://localhost:8080` from inside the instance to isolate "Jenkins isn't running" vs. "security group is blocking access" when the browser couldn't reach it externally.

## Known limitations / next steps

- SSH (22) and Jenkins UI (8080) are currently open to `0.0.0.0/0` — restrict to a specific IP/CIDR for anything beyond testing.
- No HTTPS/TLS in front of Jenkins (raw HTTP on port 8080).
- Bootstrap logic lives in an inline `user_data` script, which is fragile (as shown by the issues above). A more robust approach would bake Jenkins into a custom AMI with Packer, or move provisioning to Ansible/a configuration management tool.
- Single AZ, single instance — no high availability or Auto Scaling.
- State is local; for team use this should move to a remote backend (S3 + DynamoDB lock table).
