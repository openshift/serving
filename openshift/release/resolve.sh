#!/usr/bin/env bash

function resolve_resources(){
  local dir=$1
  local resolved_file_name=$2

  echo "Writing resolved yaml to $resolved_file_name"

  > "$resolved_file_name"

  for yaml in `find $dir -name "*.yaml" | sort`; do
    resolve_file "$yaml" "$resolved_file_name"
  done
}

function resolve_file() {
  local file=$1
  local to=$2

  # Skip nscert, it's not part of upstream's release YAML either.
  if grep -q 'networking.knative.dev/wildcard-certificate-provider: nscert' "$1"; then
    return
  fi

  echo "---" >> "$to"
  # 1. Rewrite image references
  # 2. Update config map entry
  # 3. Replace serving.knative.dev/release label.
  sed -e "s+serving.knative.dev/release: devel+serving.knative.dev/release: \"v0.23.0\"+" \
      "$file" >> "$to"
}
