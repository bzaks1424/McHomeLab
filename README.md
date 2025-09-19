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

~~The gist *should* look something like this:~~

I'm just going to update this as I understand more and more so the flow is clear to me.
1. New hot server file is committed
2. GHA (or whatever) kicks off Ansible playbook for $svr 
3. The project is cloned, poetry installs and activates the environment. Now Ansible executables are available.
4. Ansible kicks off "site.yml" which goes through the entire site and validates all the things:
   * For each "hostname.yml" in host_vars (for my use case):
     * Check inventory - Does it exist?
       * If not - create it via terraform (cloud-init for IP, DNS, hostname, LVM, SSH keys, User, etc..)
     * Check Inventory again to update existing inventory
     * Apply playbook for all configs / settings / etc.. (NTP)

## TODO for McHomeLab:

### IoT
- [ ] Move IoT Gateway IP to .1
- [ ] Migrate homeassist to .254
  - [ ] DNS: ha.example.com
- [ ] Move printer to .253
  - [ ] DNS: printer.example.com
- [ ] Move Internet Facing Devices to high range
  - [ ] Workout Roku     (.242)
  - [ ] MBR Roku         (.243)
  - [ ] Den Roku         (.244)
  - [ ] Bedroom Display  (.245)
  - [ ] MBath Speaker    (.246)
  - [ ] Kitchen Speaker  (.247)
  - [ ] Office Speaker   (.248)
  - [ ] Basement Speaker (.249)
- [ ] Block internet access for any non-internet approved devices. (245-254)

### Ansible / Terraform
- [x] VMware Inventory Plugin Working
- [ ] Build out common specs and apply to existing inventory. If I'm going to screw up things; screw up things I'm replacing.
  - [ ] SSH Keys
  - [ ] NTP Settings
  - [ ] sudo settings
  - [ ] update-alternative --config editor
  - [ ] syslog
- [ ] Build out terraform to generate server based on hostname.yml vars.
- [ ] Use playbook to spin up pxe esxi server (pxesxi.example.com? or in util?)
- [ ] Build Ansible to configure ESXi 
  - [ ] Enable SSH
  - [ ] VSS Port Groups
  - [ ] vMotion enabled
  - [ ] Scratch LUNs
  - [ ] NTP
  - [ ] syslog
- [ ] Create util.example.com

### MGMT-P
- [ ] Set router.example.com DNS
- [ ] Migrate Synology IP
  - [ ] DNS: synology.example.com
- [ ] Build new ESXi Servers via PXE/Ansible
- [ ] Update DHCP scope for MGMT-P to .10-.30

### DMZ
- [ ] Build new Plex Server
  - [ ] Update Port Forwarding
  - [ ] DNS: plex.example.com
- [ ] Build new Unifi Server
  - [ ] Migrate to new one - it's a new URI internally - externally the same.
  - [ ] Update port forwarding to the new one once internal is stabilized.
  - [ ] Split Horizon DNS: unifi.example.com (public / 192.168.255.)

### MGMT-V
- [ ] Delete vCenter01
- [ ] Install vcenter on .2 (playbook validating DNS in Unifi?)


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