import glob
import os

scanners_dir = r"c:\Users\utilisateur\Desktop\VOC_PROJECT\scanners"
yaml_files = glob.glob(os.path.join(scanners_dir, "*.yaml"))

for file_path in yaml_files:
    filename = os.path.basename(file_path)
    if filename not in ["ffuf-job.yaml", "grype-job.yaml", "nuclei-phase2-job.yaml", "sqlmap-job.yaml", "xss-job.yaml"]:
        continue
        
    print(f"Optimizing resources in {filename}")
    
    # We want to replace the resources block with requests and limits
    with open(file_path, "r", encoding="utf-8") as f:
        lines = f.readlines()
        
    new_lines = []
    in_resources = False
    for line in lines:
        if "resources:" in line:
            in_resources = True
            indent = len(line) - len(line.lstrip())
            new_lines.append(line)
            # Determine memory limits based on scanner type
            mem_limit = "512Mi"
            if filename == "nuclei-phase2-job.yaml":
                mem_limit = "1024Mi"
            elif filename == "grype-job.yaml" or filename == "sqlmap-job.yaml":
                mem_limit = "1024Mi"
                
            new_lines.append(" " * (indent + 2) + "requests:\n")
            new_lines.append(" " * (indent + 4) + "cpu: \"100m\"\n")
            new_lines.append(" " * (indent + 4) + "memory: \"128Mi\"\n")
            new_lines.append(" " * (indent + 2) + "limits:\n")
            new_lines.append(" " * (indent + 4) + f"cpu: \"1\"\n")
            new_lines.append(" " * (indent + 4) + f"memory: \"{mem_limit}\"\n")
            continue
            
        if in_resources:
            # Skip any lines that are part of the old resources block
            # (which are indented more than the resources: line)
            l_indent = len(line) - len(line.lstrip())
            if line.strip() == "" or l_indent > indent:
                continue
            else:
                in_resources = False
                
        new_lines.append(line)
        
    with open(file_path, "w", encoding="utf-8", newline="\n") as f:
        f.writelines(new_lines)
