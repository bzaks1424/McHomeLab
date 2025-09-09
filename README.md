# Auto Home Lab

## Goals
The Goal of this project is take my entire home lab and turn it into a revisionable history with git integration and ideally Harness or some kind of pipeline driving the engine in the long run. 

### Notes
Basically - Ansible can orchestrate terraform - ergo I can basically describe all the things to build a specific VM and it can orchestrate the entire thing soup to nuts.

So I have to come up with everything that matters per build - I should *only* need to Ansible variables for a server - I can generate cloud-init and everybody else and inject as runtime vars for terraform apply.
 
• Server name (unifi) also VM Name
• IP address
• Network
• Disk Size (LVM that shit) 
• Storage LUN
• ISO path

The gist *should* look something like this:
1. New hot server file is committed
2. GHA (or whatever) kicks off Ansible playbook for $svr 
3. Ideally - I can use dynamic inventory to determine whether or not to run terraform step
4. Terraform has cloud-init step that can be used for LVM, IP, Hostname, Python3, etc...
5. After server is online Ansible drives all configuration
6. Cron for scheduling update runs or CI/CD tool

Getting started:
I think first I need to get Ansible up and able to run terraform against my vcenter. Ideally I can get a check against that dynamic inventory.

```
.
├── pyproject.toml
├── poetry.lock
├── ansible/
│   ├── inventories/
│   │   ├── production/
│   │   │   └── hosts.ini
│   │   └── development/
│   │       └── hosts.ini
│   ├── playbooks/
│   │   └── deploy_application.yml
│   └── ansible.cfg
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars
└── README.md
```