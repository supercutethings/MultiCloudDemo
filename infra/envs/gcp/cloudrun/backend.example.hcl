# Copy to backend.hcl (git-ignored), or pass the same keys with -backend-config.
# Create the bucket once:
#   gcloud storage buckets create gs://<project>-tfstate --location=europe-west1 \
#     --uniform-bucket-level-access --public-access-prevention
#   gcloud storage buckets update gs://<project>-tfstate --versioning
bucket = "REPLACE-ME-tfstate"
