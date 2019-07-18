#!/usr/bin/env bash

function resolve_resources(){
  local dir=$1
  local resolved_file_name=$2
  local image_prefix=$3
  local image_tag=$4

  [[ -n $image_tag ]] && image_tag=":$image_tag"

  echo "Writing resolved yaml to $resolved_file_name"

  > "$resolved_file_name"

  for yaml in "$dir"/*.yaml; do
    resolve_file "$yaml" "$resolved_file_name" "$image_prefix" "$image_tag"
  done
}

function resolve_file() {
  local file=$1
  local to=$2
  local image_prefix=$3
  local image_tag=$4

  echo "---" >> "$to"
  # 1. Rewrite image references
  # 2. Update config map entry
  # 3. Remove comment lines
  # 4. Remove empty lines
  sed -e "s+\(.* image: \)\(knative.dev\)\(.*/\)\(.*\)+\1${image_prefix}\4${image_tag}+g" \
      -e "s+\(.* queueSidecarImage: \)\(knative.dev\)\(.*/\)\(.*\)+\1${image_prefix}\4${image_tag}+g" \
      -e '/^[ \t]*#/d' \
      -e '/^[ \t]*$/d' \
      "$file" >> "$to"
}
