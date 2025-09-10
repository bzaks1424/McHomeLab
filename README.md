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

~~ The gist *should* look something like this: ~~
I'm just going to update this as I understand more and more so the flow is clear to me.
1. New hot server file is committed
2. GHA (or whatever) kicks off Ansible playbook for $svr 
3. The project is cloned, poetry installs and activates the environment. Now Ansible executables are available.
4. Ansible kicks off "site.yml" which goes through the entire site and validates all the things:
   * For each "hostname.yml" in host_vars (for my use case):
     * Check inventory - Does it exist?
       * If not - create it.
     * Apply 
~~ 3. Ideally - I can use dynamic inventory to determine whether or not to run terraform step ~~
~~ 4. Terraform has cloud-init step that can be used for LVM, IP, Hostname, Python3, etc... ~~
~~ 5. After server is online Ansible drives all configuration ~~
~~ 6. Cron for scheduling update runs or CI/CD tool ~~

Getting started:
~~ I think first I need to get Ansible up and able to run terraform against my vcenter. Ideally I can get a check against that dynamic inventory. ~~




```
├── pyproject.toml
├── poetry.lock
├── ansible/
│   ├── group_vars/
│   │   ├── group1.yml             # here we assign variables to particular groups
│   │   └── group2.yml
│   ├── host_vars/
│   │   └── hostname1.yml          # here we assign variables to particular systems
|   |   └── hostname2.yml
│   ├── library/                  # if any custom modules, put them here (optional)
│   ├── module_utils/             # if any custom module_utils to support modules, put them here (optional)
│   ├── filter_plugins/           # if any custom filter plugins, put them here (optional)
│   ├── site.yml                  # main playbook
│   ├── webservers.yml            # playbook for webserver tier
│   ├── dbservers.yml             # playbook for dbserver tier
│   ├── tasks/                    # task files included from playbooks
|   |   └── hostname2.yml
│   ├── roles/
│   │   └── common/               # this hierarchy represents a "role"
│   │   |   ├── tasks/            #
|   |   |   |    └── main.yml      #  <-- tasks file can include smaller files if warranted
│   │   |   ├── handlers/         #
|   |   |   |    └── main.yml      #  <-- handlers file
│   │   |   ├── templates/        #  <-- files for use with the template resource
|   |   |   |    └── ntp.conf.j2   #  <------- templates end in .j2
│   │   |   ├── files/            #
|   |   |   |    └── bar.txt       #  <-- files for use with the copy resource
|   |   |   |    └── foo.sh        #  <-- script files for use with the script resource
│   │   |   ├── vars/             #
|   |   |   |    └── main.yml      #  <-- variables associated with this role
│   │   |   ├── defaults/         #
|   |   |   |    └── main.yml      #  <-- default lower priority variables for this role
│   │   |   ├── meta/             #
|   |   |   |    └── main.yml      #  <-- role dependencies and optional Galaxy info
│   │   |   ├── library/          # roles can also include custom modules
│   │   |   ├── module_utils/     # roles can also include custom module_utils
│   │   |   ├── lookup_plugins/   # or other types of plugins, like lookup in this case
│   │   └── webtier/              # same kind of structure as "common" was above, done for the webtier role
│   │   └── monitoring/           # ""
│   │   └── fooapp/               # ""
│   └── ansible.cfg
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars
└── README.md
```