# Copy to backend.hcl (git-ignored). Create the bucket once, with uniform access and
# versioning on:
#   gcloud storage buckets create gs://showcase-tfstate --uniform-bucket-level-access \
#     --public-access-prevention --location=europe-west1
#   gcloud storage buckets update gs://showcase-tfstate --versioning
bucket = "showcase-tfstate"
