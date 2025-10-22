export def execute [entry: string] {
  let roots = parse_entry_roots $entry
  let kustomize_dirs = ($roots | each {|root| find_kustomize_dirs $root } | flatten | uniq)
  let changed_dirs = changed_kustomize_dirs $kustomize_dirs
  let targets = if ($changed_dirs | is-empty) { $kustomize_dirs } else { $changed_dirs }
  if ($targets | is-empty) {
    print "⚠️ No kustomization directories found."
    return
  }
  kube_check $targets
}

def parse_entry_roots [entry: string] {
  $entry
    | split row ","
    | each {|segment| $segment | str trim }
    | where {|segment| $segment != "" }
    | each {|segment| path normalize --path $segment }
}

def find_kustomize_dirs [root: string] {
  glob $'($root)/**/kustomization.yaml'
    | each {|file| path dirname --path $file | path normalize }
    | uniq
}

def changed_kustomize_dirs [known_dirs: list<string>] {
  if ($known_dirs | is-empty) {
    return []
  }
  let diff = (git diff --name-only origin/main...HEAD | complete)
  if $diff.exit_code != 0 {
    return []
  }
  $diff.stdout
    | lines
    | where {|line| $line != "" }
    | each {|file|
        let normalized_file = (path normalize --path $file)
        $known_dirs
          | each {|dir|
              let normalized_dir = (path normalize --path $dir)
              if ($normalized_file == $normalized_dir) or ($normalized_file | str starts-with $'($normalized_dir)/') {
                $normalized_dir
              } else {
                null
              }
            }
          | compact
      }
    | flatten
    | uniq
}

def kube_check [entries: list<string>] {
  let kube_catalog = "https://kubernetesjsonschema.dev"
  let datree_catalog = "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
  let local_catalog = (path join [$env.HOME ".datree/crdSchemas"])
  for $dir in $entries {
    print "\n"
    print $'(ansi blue)👀 Checking ($dir)(ansi reset)'
    let output = (
      kustomize build $dir --enable-helm --load-restrictor LoadRestrictionsNone
      | kubeconform -schema-location default -schema-location $local_catalog -schema-location $kube_catalog -schema-location $datree_catalog -output json -ignore-missing-schemas -verbose
      | from json
    )
    let results = $output.resources
    let has_errors = $results | any {|item| $item.status == "statusError" }
    print ($results | reject filename | table -w 200 -i false)
    if $has_errors {
      print $'(ansi red)❌ Validation failed for ($dir)(ansi reset)'
      print "\n"
      exit 1
    } else {
      print $'(ansi green)✅ Nicely done, validation succeeded(ansi reset)'
      print "\n"
    }
  }
}
