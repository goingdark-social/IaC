# Nushell 0.93 compatible. No reliance on `path` subcommands.
# Uses external `realpath` and `dirname` for canonicalization.

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

# Helpers

def canon [p: string] {
  # Canonicalize without requiring the path to exist. GNU realpath supports -m.
  try {
    ^realpath -m $p | str trim
  } catch {
    # Fallback. Return input if realpath is unavailable.
    $p | str trim
  }
}

def dname [p: string] {
  try {
    ^dirname $p | str trim
  } catch {
    $p
  }
}

def is-abs [p: string] {
  # Linux runner. Treat leading slash as absolute.
  $p | str starts-with "/"
}

def workspace-root [] {
  if ($env | columns | any {|c| $c == "GITHUB_WORKSPACE"}) {
    canon $env.GITHUB_WORKSPACE
  } else {
    canon (pwd)
  }
}

def resolve-entry [entry repo_root] {
  let trimmed = ($entry | str trim)
  if ($trimmed | is-empty) {
    $repo_root
  } else {
    if (is-abs $trimmed) {
      canon $trimmed
    } else {
      canon ($"($repo_root)/($trimmed)")
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
  let git_root = (try { ^git rev-parse --show-toplevel | str trim } catch { "" })
  if ($git_root | is-empty) {
    []
  } else {
    let diff_ref = (diff-target)
    if ($diff_ref | is-empty) {
      []
    } else {
      let files = (try { ^git diff --name-only $diff_ref HEAD | lines } catch { [] })
      $files
        | filter-manifest-paths $entry_path
        | uniq
        | sort
        | each {|seg| canon $seg }
    }
  }
}

def diff-target [] {
  if ($env | columns | any {|c| $c == "GITHUB_BASE_REF"} && ($env.GITHUB_BASE_REF | str trim | is-empty) == false) {
    $"origin/($env.GITHUB_BASE_REF)"
  } else if ($env | columns | any {|c| $c == "GITHUB_EVENT_NAME"} && $env.GITHUB_EVENT_NAME == "push") {
    try { ^git rev-parse HEAD^ | str trim } catch { "" }
  } else {
    try {
      let def = (^git symbolic-ref refs/remotes/origin/HEAD | str trim | str replace "refs/remotes/origin/" "")
      if ($def | is-empty) { "origin/main" } else { $"origin/($def)" }
    } catch {
      "origin/main"
    }
  }
}

def filter-manifest-paths [entry_path] {
  let base = (canon $entry_path)
  each {|file|
    let f = (canon $file)
    if ($f | str starts-with $"($base)/") or ($f == $base) {
      canon (dname $f)
    } else {
      null
    }
  } | where {|v| $v != null } | uniq
}

def find-kustomize-dirs [entry_path] {
  let base = (canon $entry_path)
  let patterns = [
    $"($base)/**/kustomization.yaml"
    $"($base)/**/kustomization.yml"
  ]
  $patterns
    | each {|pat| glob $pat }
    | flatten
    | each {|f| canon (dname $f) }
    | uniq
    | sort
}

def datree-cache-path [] {
  let home = (if ($env | columns | any {|c| $c == "HOME"}) { $env.HOME } else { pwd })
  canon ($"($home)/.datree/crdSchemas")
}

def run-validation [targets] {
  let kube_catalog = "https://kubernetesjsonschema.dev"
  let datree_catalog = "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
  let local_catalog = (datree-cache-path)
  for dir in $targets {
    let d = (canon $dir)
    print "\n"
    print $'(ansi blue)👀 Checking ($d)(ansi reset)'
    let validation = (try {
        ^kustomize build $d --enable-helm --load-restrictor LoadRestrictionsNone
        | ^kubeconform -schema-location default -schema-location $local_catalog -schema-location $kube_catalog -schema-location $datree_catalog -output json -ignore-missing-schemas -verbose
        | from json
      } catch {|err|
        print $'(ansi red)❌ Failed to validate ($d): ($err.msg)(ansi reset)'
        exit 1
      })
    if ($validation | is-empty) {
      print $'(ansi red)❌ kubeconform returned no data for ($d)(ansi reset)'
      exit 1
    }
    let results = ($validation.resources | default [])
    if ($results | is-empty) {
      print $'(ansi yellow)⚠️ No resources produced by kustomize for ($d)(ansi reset)'
      continue
    }
    let rows = ($results | reject filename)
    print ($rows | table -w 200 -i false)
    let failures = ($results | where status == "statusError")
    if ($failures | is-empty) {
      print $'(ansi green)✅ Nicely done, validation succeeded(ansi reset)'
    } else {
      print $'(ansi red)❌ Validation failed for ($d)(ansi reset)'
      exit 1
    }
  }
}
