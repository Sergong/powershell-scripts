# Installing Terraform on Windows Server

To install Terraform on a Windows Server, follow these steps:

1. **Download Terraform:**
   - Go to the official Terraform downloads page: https://www.terraform.io/downloads.html
   - Download the Windows 64-bit ZIP archive.

2. **Extract the ZIP:**
   - Extract the `terraform.exe` from the ZIP archive to a folder, e.g., `C:\terraform`.

3. **Add Terraform to system PATH:**
   - Open the Start menu, search for "Environment Variables," and open "Edit the system environment variables."
   - Click "Environment Variables..."
   - Under "System variables," find and select the `Path` variable, then click "Edit..."
   - Click "New" and add the path to the folder where `terraform.exe` resides, e.g., `C:\terraform`.
   - Click OK through all dialog boxes.

4. **Verify installation:**
   - Open Command Prompt or PowerShell and run:
     ```
     terraform -version
     ```
   - You should see the installed Terraform version output.

**Optional:** You can also install Terraform using package managers like Chocolatey by running:
```
choco install terraform
```
if Chocolatey is installed.

This method installs Terraform on your Windows Server, making it available in your command line environment.

