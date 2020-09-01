#!/usr/bin/env bash

function resolve_resources(){
  local dir=$1
  local resolved_file_name=$2
  local image_prefix=$3
  local image_tag=$4

  [[ -n $image_tag ]] && image_tag=":$image_tag"

  echo "Writing resolved yaml to $resolved_file_name"

  > "$resolved_file_name"

  for yaml in `find $dir -name "*.yaml"`; do
    resolve_file "$yaml" "$resolved_file_name" "$image_prefix" "$image_tag"
  done
}

function resolve_file() {
  local file=$1
  local to=$2
  local image_prefix=$3
  local image_tag=$4

  # Skip cert-manager, it's not part of upstream's release YAML either.
  if grep -q 'networking.knative.dev/certificate-provider: cert-manager' "$1"; then
    return
  fi

  # Skip nscert, it's not part of upstream's release YAML either.
  if grep -q 'networking.knative.dev/wildcard-certificate-provider: nscert' "$1"; then
    return
  fi

  # Skip istio resources, as we use kourier.
  if grep -q 'networking.knative.dev/ingress-provider: istio' "$1"; then
    return
  fi

  echo "---" >> "$to"
  # 1. Rewrite image references
  # 2. Update config map entry
  sed -e "s+\(.* image: \)\(knative.dev\)\(.*/\)\(.*\)+\1${image_prefix}\4${image_tag}+g" \
      -e "s+\(.* queueSidecarImage: \)\(knative.dev\)\(.*/\)\(.*\)+\1${image_prefix}\4${image_tag}+g" \
      "$file" >> "$to"
}
