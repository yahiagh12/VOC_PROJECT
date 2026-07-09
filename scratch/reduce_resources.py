import glob
import os

scanners_dir = r"c:\Users\utilisateur\Desktop\VOC_PROJECT\scanners"
yaml_files = glob.glob(os.path.join(scanners_dir, "*.yaml"))

for file_path in yaml_files:
    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()
    
    # We want to change cpu: "1" to cpu: "100m"
    # and reduce memory limit or remove resources
    # Let's replace cpu: "1" with cpu: "100m"
    new_content = content.replace('cpu: "1"', 'cpu: "100m"')
    new_content = new_content.replace('cpu: 1', 'cpu: "100m"')
    new_content = new_content.replace('memory: "1024Mi"', 'memory: "256Mi"')
    new_content = new_content.replace('memory: "2048Mi"', 'memory: "512Mi"')
    new_content = new_content.replace('memory: "512Mi"', 'memory: "128Mi"')
    
    if new_content != content:
        print(f"Updating resources in {os.path.basename(file_path)}")
        with open(file_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(new_content)
