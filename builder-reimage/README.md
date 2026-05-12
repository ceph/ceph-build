# Builder Reimage

Builder Reimage is a lightweight automation utility for interacting with **MAAS (Metal as a Service)**.  
It allows you to list, query, check status, and redeploy machines efficiently, with or without specifying an operating system.

This script simplifies MAAS machine management tasks and helps maintain consistent environment setups through a command-line interface.

---

## Features
- List all managed MAAS machines  
- Query machine details  
- Check deployment or power status  
- Redeploy single or multiple machines  
- Redeploy with or without specifying an OS version  

---

## Requirements
- Python 3.8 or higher  
- MAAS CLI installed and configured  
- Valid MAAS API credentials

---

## Cloning the Repository

To get started, clone the repository and navigate into the project directory:

```bash
git clone https://github.com/jitendrasahu1803/builder-reimage.git

cd builder-reimage
```

## Setup your environment to use the tool

Run bootstrap script:
```bash
bash bootstrap_env.sh
```
Active your virtual environment:
```bash
source .venv/bin/activate
```
Edit ```bash maas.conf``` file and update it with the correct MAAS URL (Sepia/Tucson):
```bash
cat maas.conf
[maas]
maas_url=http://<Enter_MAAS_URL>/MAAS
```
To setup your credential to connect with MAAS API, run (Replace <YOUR_MAAS_API_KEY> with your actual MAAS API key):
```bash
echo -n "<YOUR_MAAS_API_KEY>" | python3 -c 'import sys; from cryptography.fernet import Fernet; key=Fernet.generate_key(); open("maas_api.key","wb").write(key); data=sys.stdin.buffer.read(); open("maas_api_key.encrypted","wb").write(Fernet(key).encrypt(data)); print("wrote: maas_api.key and maas_api_key.encrypted")'
```
---

## Usage
Activate your virtual environment (if not already active), then run:
```bash
python3 maas-reimage.py [OPTIONS]
```

## Examples
List all machines
```bash
--action list
```
Query details for one machine
```bash
--action query --machine node01
```
Check machine status
```bash
--action status --machine node01
```
Deploy a machine with a specific OS:
```bash
--action deploy --machine node01 --os 9.6
```
Reimage one machine (same OS)
```bash
--action reimage --machine node01
```
Reimage one machine with a specific OS
```bash
--action reimage --machine node01 --os jammy
```
Redeploy all machines
```bash
--action reimage-all
```
Redeploy all machines with a specific OS
```bash
--action reimage-all --os jammy
```
Find last deployed machine
```bash
--action last-deployed
```

## Additional option of (--owner)

When you deploy or reimage a machine, it is automatically tagged with the default owner ```jitendra```. If you want to assign a different owner, you can specify it using the option shown below.

Reimage a machine with a custom owner tag:
```bash
--action reimage --machine node01 --owner "<owner_name>"
```

This option works for deploy, reimage, reimage_all, and all other relevant commands.

---

## Author

Jitendra Sahu

GitHub: jitendrasahu1803

## License

This project is licensed under the MIT License.
