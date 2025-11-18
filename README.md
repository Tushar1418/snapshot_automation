# GCP Snapshot Automation

1. Ensure gcloud is authenticated and project set:
   gcloud auth login
   gcloud config set project snapshottask

2. Local dry-run:
   ./snapshot_gcp.sh --servers-file servers.txt --project snapshottask --labels env=dev,owner=boss --retention-days 7 --activity "nightly" --backup-type incremental --dry-run

3. To run real (remove dry-run):
   ./snapshot_gcp.sh --servers-file servers.txt --project snapshottask --labels env=dev,owner=boss --retention-days 7 --activity "nightly" --backup-type incremental

4. Cloud Build will run the same script from repo when trigger matches.

IAM: Build SA needs:
 - compute.instances.get
 - compute.disks.get
 - compute.disks.createSnapshot
 - compute.snapshots.create
 - compute.snapshots.delete (if cleanup runs)
 - compute.snapshots.list
# snapshot_automation
