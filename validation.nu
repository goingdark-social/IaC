# Minimal Nushell 0.93 script for the action.
# Validates all kustomizations under the given entry (default: ./kubernetes).

export def execute [entry: string] {
  let root = (entry-root $entry)
  let targets = (find-kustomize-dirs $root)

  if ($targets | is-empty) {
    print "No kustomizations discovered."
    return
  }

  validate $targets
}

def entry-root [entry: string] {
  let trimmed = ($entry | str trim)
  if ($trimmed | is-empty) { "./kubernetes" } else { $trimmed }
}

def find-kustomize-dirs [root: string] {
  let patterns = [
    $"($root)/**/kustomization.yaml"
    $"($root)/**/kustomization.yml"
  ]

  $patterns
  | each {|p| glob $p }
  | flatten
  | each {|f| ^dirname $f | str trim }
  | uniq
  | sort
}

def validate [dirs: list<string>] {
  let kube_catalog = "https://kubernetesjsonschema.dev"
  let datree_catalog = "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
  let local_catalog = ($"($env.HOME)/.datree/crdSchemas")

  for d in $dirs {
    print "\n"
    print $'(ansi blue)👀 Checking ($d)(ansi reset)'

    let out = (try {
      ^kustomize build $d --enable-helm --load-restrictor LoadRestrictionsNone
      | ^kubeconform -schema-location default -schema-location $local_catalog -schema-location $kube_catalog -schema-location $datree_catalog -output json -ignore-missing-schemas -verbose
      | from json
    } catch {|err|
      print $'(ansi red)❌ Failed to validate ($d): ($err.msg)(ansi reset)'
      exit 1
    })

    let resources = ($out.resources | default [])
    if ($resources | is-empty) {
      print $'(ansi yellow)⚠️ No resources produced by kustomize for ($d)(ansi reset)'
      continue
    }

    print (($resources | reject filename) | table -w 200 -i false)

    let failed = ($resources | where status == "statusError")
    if ($failed | is-empty) {
      print $'(ansi green)✅ Nicely done, validation succeeded(ansi reset)'
    } else {
      print $'(ansi red)❌ Validation failed for ($d)(ansi reset)'
      exit 1
    }
  }
}
