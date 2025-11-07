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
  let kube_catalog = "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master"
  let datree_catalog = "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
  let local_catalog = ($"($env.HOME)/.datree/crdSchemas")
  # Explicit CRD schema sources to eliminate "could not find schema" noise for common operators
  let crd_catalogs = [
    # cert-manager
    "https://raw.githubusercontent.com/cert-manager/cert-manager/master/deploy/crds/{kind}.yaml"
    # external-secrets
    "https://raw.githubusercontent.com/external-secrets/external-secrets/main/config/crds/{kind}.yaml"
    # cloudnative-pg
    "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/main/config/crd/bases/{kind}.yaml"
    # elastic operator
    "https://raw.githubusercontent.com/elastic/cloud-on-k8s/main/config/crds/{kind}.yaml"
    # gateway api (standard set)
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/main/config/crd/standard/{kind}.yaml"
    # victoria metrics operator
    "https://raw.githubusercontent.com/VictoriaMetrics/operator/master/config/crd/bases/{kind}.yaml"
  ]

  for d in $dirs {
    print "\n"
    print $'(ansi blue)👀 Checking ($d)(ansi reset)'

    let kubeconform_cmd = (['kubeconform'
      '-output' 'json'
      '-strict'
      '-verbose'
      # default built-in
      '-schema-location' 'default'
      # local cache
      '-schema-location' $local_catalog
      # generic catalogs
      '-schema-location' $kube_catalog
      '-schema-location' $datree_catalog] ++ ($crd_catalogs | each {|c| ['-schema-location' $c] } | flatten))

    let out = (try {
      ^kustomize build $d --enable-helm --load-restrictor LoadRestrictionsNone
      | ^$kubeconform_cmd
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
