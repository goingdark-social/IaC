export def execute [entry: string] {
  let repo_root = (workspace-root)
  let entry_path = (resolve-entry $entry $repo_root)
  let targets = (pick-targets $entry_path)
  if ($targets | is-empty) {
    print "No kustomizations discovered."
    return
  }
  run-validation $targets
}

def workspace-root [] {
  if ($env | columns | any {|col| $col == "GITHUB_WORKSPACE"}) {
    path normalize $env.GITHUB_WORKSPACE
  } else {
    path normalize (pwd)
  }
}

def resolve-entry [entry repo_root] {
  let trimmed = ($entry | str trim)
  if ($trimmed | is-empty) {
    $repo_root
  } else {
    let kind = (echo $trimmed | path type)
    if $kind == "absolute" {
      path normalize $trimmed
    } else {
      path normalize (path join $repo_root $trimmed)
    }
  }
}

def pick-targets [entry_path] {
  let changed = (changed-kustomize-dirs $entry_path)
  if ($changed | is-empty) {
    find-kustomize-dirs $entry_path
  } else {
    $changed
  }
}

def changed-kustomize-dirs [entry_path] {
  let git_root = (try {
      ^git rev-parse --show-toplevel | str trim
    } catch {
      ""
    })
  if ($git_root | is-empty) {
    []
  } else {
    let diff_ref = (diff-target)
    if ($diff_ref | is-empty) {
      []
    } else {
      let files = (try {
          ^git diff --name-only $diff_ref HEAD | lines
        } catch {
          []
        })
      $files
        | filter-manifest-paths $entry_path
        | uniq
        | sort
        | each {|segment| path normalize $segment }
    }
  }
}

def diff-target [] {
  if ($env | columns | any {|col| $col == "GITHUB_BASE_REF"} && ($env.GITHUB_BASE_REF | str trim | is-empty) == false) {
    $"origin/($env.GITHUB_BASE_REF)"
  } else if ($env | columns | any {|col| $col == "GITHUB_EVENT_NAME"} && $env.GITHUB_EVENT_NAME == "push") {
    (try {
      ^git rev-parse HEAD^ | str trim
    } catch {
      ""
    })
  } else {
    (try {
      let default_branch = (^git symbolic-ref refs/remotes/origin/HEAD | str trim | str replace "refs/remotes/origin/" "")
      if ($default_branch | is-empty) {
        "origin/main"
      } else {
        $"origin/($default_branch)"
      }
    } catch {
      "origin/main"
    })
  }
}

def filter-manifest-paths [entry_path] {
  let normalized_entry = (path normalize $entry_path)
  each {|file|
    let normalized_file = (path normalize $file)
    if ($normalized_file | str contains $normalized_entry) {
      echo $normalized_file | path dirname | path normalize
    } else {
      null
    }
  }
  | where {|value| $value != null }
  | uniq
}

def find-kustomize-dirs [entry_path] {
  let patterns = [
    $"($entry_path)/**/kustomization.yaml",
    $"($entry_path)/**/kustomization.yml"
  ]
  $patterns
    | each {|pattern| glob $pattern }
    | flatten
    | each {|file| echo $file | path dirname | path normalize }
    | uniq
    | sort
    | each {|segment| path normalize $segment }
}

def datree-cache-path [] {
  let base = (if ($env | columns | any {|col| $col == "HOME"}) {
      $env.HOME
    } else {
      (pwd)
    })
  path normalize (path join $base ".datree" "crdSchemas")
}

def run-validation [targets] {
  let kube_catalog = "https://kubernetesjsonschema.dev"
  let datree_catalog = "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
  let local_catalog = (datree-cache-path)
  for dir in $targets {
    let normalized_dir = (path normalize $dir)
    print "\n"
    print $'(ansi blue)👀 Checking ($normalized_dir)(ansi reset)'
    let validation = (try {
        ^kustomize build $normalized_dir --enable-helm --load-restrictor LoadRestrictionsNone
        | ^kubeconform -schema-location default -schema-location $local_catalog -schema-location $kube_catalog -schema-location $datree_catalog -output json -ignore-missing-schemas -verbose
        | from json
      } catch {|err|
        print $'(ansi red)❌ Failed to validate ($normalized_dir): ($err.msg)(ansi reset)'
        exit 1
      })
    if ($validation | is-empty) {
      print $'(ansi red)❌ kubeconform returned no data for ($normalized_dir)(ansi reset)'
      exit 1
    }
    let results = ($validation.resources | default [])
    if ($results | is-empty) {
      print $'(ansi yellow)⚠️ No resources produced by kustomize for ($normalized_dir)(ansi reset)'
      continue
    }
    let table_rows = ($results | reject filename)
    print ($table_rows | table -w 200 -i false)
    let failures = ($results | where status == "statusError")
    if ($failures | is-empty) {
      print $'(ansi green)✅ Nicely done, validation succeeded(ansi reset)'
    } else {
      print $'(ansi red)❌ Validation failed for ($normalized_dir)(ansi reset)'
      exit 1
    }
  }
}
