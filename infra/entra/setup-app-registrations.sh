#!/usr/bin/env bash
# Creates the three Entra app registrations for the Library POC and writes
# their IDs and secrets into ../../.env.
#
#   <prefix>-portal       Library Portal: confidential web client (OIDC sign-in)
#   <prefix>-patron-api   Patron Record API: exposes scopes + app roles, and is
#                         itself a confidential client for OBO to Microsoft Graph
#   <prefix>-notices-job  Overdue-notices job: client credentials, app role only
#
# Run in Azure Cloud Shell (bash) or any shell with az CLI + python3, signed in
# as a user who can create app registrations and grant admin consent
# (Application Administrator / Cloud Application Administrator + Privileged
# Role Administrator for app-role consent, or Global Administrator).
#
# Options (environment variables):
#   PREFIX=library-poc                 name prefix for the registrations
#   EXTRA_REDIRECT_URIS="https://..."  more portal redirect URIs (deploy.sh adds Azure's)
#   CREATE_TEST_USERS=true             create jstudent/mfaculty/llibrarian/aalumni users
#   ASSIGN_ROLES_TO_ME="Student,Librarian"  give the signed-in user these app roles
set -euo pipefail

PREFIX="${PREFIX:-library-poc}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$ROOT/.env"
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
LOCAL_REDIRECT="http://localhost:3000/auth/entra_id/callback"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
log() { printf '\n==> %s\n' "$*"; }
graph() { az rest --headers Content-Type=application/json --only-show-errors "$@"; }
patch_app() { graph --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$1" --body "@$2" >/dev/null; }
retry() { local n=0; until "$@"; do n=$((n + 1)); [ $n -ge 6 ] && return 1; echo "   (waiting for directory replication, retry $n)"; sleep 10; done; }

graph_scope_id() {
  az ad sp show --id "$GRAPH_APP_ID" --query "oauth2PermissionScopes[?value=='$1'].id | [0]" -o tsv
}

new_secret() {
  az ad app credential reset --id "$1" --append --display-name "poc-$(date +%Y%m%d)" --years 1 \
    --query password -o tsv --only-show-errors
}

for name in portal patron-api notices-job; do
  if [ -n "$(az ad app list --display-name "$PREFIX-$name" --query '[].appId' -o tsv)" ]; then
    echo "App registration '$PREFIX-$name' already exists. Run infra/entra/teardown.sh first, or set PREFIX." >&2
    exit 1
  fi
done

TENANT_ID="$(az account show --query tenantId -o tsv)"
log "Tenant $TENANT_ID"

# ---------------------------------------------------------------------------
log "1/6 Portal registration (created first so the API can list it as a known client)"
REDIRECTS="$LOCAL_REDIRECT ${EXTRA_REDIRECT_URIS:-}"
# shellcheck disable=SC2086
PORTAL_APP_ID="$(az ad app create --display-name "$PREFIX-portal" --sign-in-audience AzureADMyOrg \
  --web-redirect-uris $REDIRECTS --query appId -o tsv --only-show-errors)"
PORTAL_OBJ="$(az ad app show --id "$PORTAL_APP_ID" --query id -o tsv)"

# ---------------------------------------------------------------------------
log "2/6 Patron API registration: scopes, app roles, v2 tokens, Graph permissions"
PATRON_API_APP_ID="$(az ad app create --display-name "$PREFIX-patron-api" --sign-in-audience AzureADMyOrg \
  --query appId -o tsv --only-show-errors)"
PATRON_API_OBJ="$(az ad app show --id "$PATRON_API_APP_ID" --query id -o tsv)"

SCOPE_READ="$(uuid)"; SCOPE_MANAGE="$(uuid)"
ROLE_STUDENT="$(uuid)"; ROLE_FACULTY="$(uuid)"; ROLE_STAFF="$(uuid)"; ROLE_LIBRARIAN="$(uuid)"
ROLE_ALUMNI="$(uuid)"; ROLE_NOTICES="$(uuid)"
GRAPH_CALENDARS="$(graph_scope_id Calendars.ReadWrite)"
GRAPH_USER_READ="$(graph_scope_id User.Read)"

user_role() { # id value description
  printf '{"id":"%s","value":"%s","displayName":"%s","description":"%s","allowedMemberTypes":["User"],"isEnabled":true}' \
    "$1" "$2" "$2" "$3"
}

cat >"$TMP/patron-api.json" <<JSON
{
  "identifierUris": ["api://$PATRON_API_APP_ID"],
  "api": {
    "requestedAccessTokenVersion": 2,
    "knownClientApplications": ["$PORTAL_APP_ID"],
    "oauth2PermissionScopes": [
      {
        "id": "$SCOPE_READ", "value": "Patron.Read", "type": "User", "isEnabled": true,
        "adminConsentDisplayName": "Read the signed-in patron's library record",
        "adminConsentDescription": "Lets the app read the signed-in patron's loans, fines and profile, and add due-date reminders to their calendar.",
        "userConsentDisplayName": "Read your library record",
        "userConsentDescription": "Lets the app read your loans, fines and profile, and add due-date reminders to your calendar."
      },
      {
        "id": "$SCOPE_MANAGE", "value": "Patron.Manage", "type": "Admin", "isEnabled": true,
        "adminConsentDisplayName": "Manage patron records as the signed-in librarian",
        "adminConsentDescription": "Lets the app look up patrons and waive fines on behalf of a signed-in user who holds the Librarian role."
      }
    ]
  },
  "appRoles": [
    $(user_role "$ROLE_STUDENT" Student "Current student"),
    $(user_role "$ROLE_FACULTY" Faculty "Faculty member"),
    $(user_role "$ROLE_STAFF" Staff "University staff"),
    $(user_role "$ROLE_LIBRARIAN" Librarian "Library staff with patron management rights"),
    $(user_role "$ROLE_ALUMNI" Alumni "Alumni or community borrower: print only, no licensed e-resources"),
    {
      "id": "$ROLE_NOTICES", "value": "Notices.Read.All", "displayName": "Read overdue notices",
      "description": "Lets a background job read all overdue loans to send notices.",
      "allowedMemberTypes": ["Application"], "isEnabled": true
    }
  ],
  "optionalClaims": { "accessToken": [ { "name": "idtyp", "essential": false } ] },
  "requiredResourceAccess": [
    {
      "resourceAppId": "$GRAPH_APP_ID",
      "resourceAccess": [
        { "id": "$GRAPH_CALENDARS", "type": "Scope" },
        { "id": "$GRAPH_USER_READ", "type": "Scope" }
      ]
    }
  ]
}
JSON
retry patch_app "$PATRON_API_OBJ" "$TMP/patron-api.json"

# ---------------------------------------------------------------------------
log "3/6 Portal permissions: sign-in scopes + Patron.Read + Patron.Manage"
cat >"$TMP/portal.json" <<JSON
{
  "requiredResourceAccess": [
    {
      "resourceAppId": "$GRAPH_APP_ID",
      "resourceAccess": [
        { "id": "$(graph_scope_id openid)", "type": "Scope" },
        { "id": "$(graph_scope_id profile)", "type": "Scope" },
        { "id": "$(graph_scope_id email)", "type": "Scope" },
        { "id": "$(graph_scope_id offline_access)", "type": "Scope" }
      ]
    },
    {
      "resourceAppId": "$PATRON_API_APP_ID",
      "resourceAccess": [
        { "id": "$SCOPE_READ", "type": "Scope" },
        { "id": "$SCOPE_MANAGE", "type": "Scope" }
      ]
    }
  ]
}
JSON
retry patch_app "$PORTAL_OBJ" "$TMP/portal.json"

# ---------------------------------------------------------------------------
log "4/6 Notices job registration: application permission Notices.Read.All"
JOB_APP_ID="$(az ad app create --display-name "$PREFIX-notices-job" --sign-in-audience AzureADMyOrg \
  --query appId -o tsv --only-show-errors)"
JOB_OBJ="$(az ad app show --id "$JOB_APP_ID" --query id -o tsv)"
cat >"$TMP/job.json" <<JSON
{ "requiredResourceAccess": [ { "resourceAppId": "$PATRON_API_APP_ID",
    "resourceAccess": [ { "id": "$ROLE_NOTICES", "type": "Role" } ] } ] }
JSON
retry patch_app "$JOB_OBJ" "$TMP/job.json"

# ---------------------------------------------------------------------------
log "5/6 Service principals, secrets and admin consent"
for app in "$PORTAL_APP_ID" "$PATRON_API_APP_ID" "$JOB_APP_ID"; do
  retry az ad sp create --id "$app" --only-show-errors >/dev/null
done
PATRON_API_SP="$(az ad sp show --id "$PATRON_API_APP_ID" --query id -o tsv)"
JOB_SP="$(az ad sp show --id "$JOB_APP_ID" --query id -o tsv)"

PORTAL_SECRET="$(new_secret "$PORTAL_APP_ID")"
PATRON_API_SECRET="$(new_secret "$PATRON_API_APP_ID")"
JOB_SECRET="$(new_secret "$JOB_APP_ID")"

# Delegated permissions, tenant-wide: the portal -> Patron API, and the
# Patron API -> Graph (which OBO needs; there is no interactive consent there).
# retry az ad app permission admin-consent --id "$PATRON_API_APP_ID" --only-show-errors
# retry az ad app permission admin-consent --id "$PORTAL_APP_ID" --only-show-errors

assign_app_role() { # principal-object-id app-role-id
  graph --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$PATRON_API_SP/appRoleAssignedTo" \
    --body "{\"principalId\":\"$1\",\"resourceId\":\"$PATRON_API_SP\",\"appRoleId\":\"$2\"}" >/dev/null
}
# Application permission = an app role assigned to the job's service principal.
retry assign_app_role "$JOB_SP" "$ROLE_NOTICES"

role_id() {
  case "$1" in
    Student) echo "$ROLE_STUDENT" ;; Faculty) echo "$ROLE_FACULTY" ;; Staff) echo "$ROLE_STAFF" ;;
    Librarian) echo "$ROLE_LIBRARIAN" ;; Alumni) echo "$ROLE_ALUMNI" ;;
    *) echo "Unknown role $1" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
log "6/6 Users and role assignments"
if [ -n "${ASSIGN_ROLES_TO_ME:-}" ]; then
  ME="$(az ad signed-in-user show --query id -o tsv)"
  IFS=',' read -ra MY_ROLES <<<"$ASSIGN_ROLES_TO_ME"
  for r in "${MY_ROLES[@]}"; do retry assign_app_role "$ME" "$(role_id "$r")"; echo "   you -> $r"; done
fi

if [ "${CREATE_TEST_USERS:-false}" = "true" ]; then
  DOMAIN="$(graph --method GET --uri https://graph.microsoft.com/v1.0/domains --query "value[?isDefault].id | [0]" -o tsv)"
  CREDS="$ROOT/infra/entra/test-users.txt"
  : >"$CREDS"; chmod 600 "$CREDS"
  # NetID:Display name:roles (mirrors mock-cas/users.yml affiliations)
  for spec in "jstudent:Jordan Student:Student" "mfaculty:Morgan Faculty:Faculty" \
              "llibrarian:Lee Librarian:Staff,Librarian" "aalumni:Avery Alumni:Alumni"; do
    IFS=':' read -r netid display roles <<<"$spec"
    upn="$netid@$DOMAIN"
    pw="$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("Lib-"+"".join(secrets.choice(a) for _ in range(14))+"!9")')"
    uid="$(az ad user create --display-name "$display" --user-principal-name "$upn" --password "$pw" \
      --force-change-password-next-sign-in false --query id -o tsv --only-show-errors)"
    IFS=',' read -ra user_roles <<<"$roles"
    for r in "${user_roles[@]}"; do retry assign_app_role "$uid" "$(role_id "$r")"; done
    echo "$upn  $pw  ($roles)" >>"$CREDS"
    echo "   $upn -> $roles"
  done
  echo "   Passwords written to infra/entra/test-users.txt (delete it after the demo)."
  echo "   Note: Graph calendar writes need an Exchange Online mailbox (a licence) on the user."
fi

# ---------------------------------------------------------------------------
[ -f "$ENV_FILE" ] || cp "$ROOT/.env.example" "$ENV_FILE"
KEYS="ENTRA_TENANT_ID PORTAL_CLIENT_ID PORTAL_CLIENT_SECRET PATRON_API_CLIENT_ID PATRON_API_CLIENT_SECRET JOB_CLIENT_ID JOB_CLIENT_SECRET PATRON_API_SCOPES PATRON_API_APP_SCOPE"
pattern="$(echo "$KEYS" | sed 's/ /=|^/g')"
grep -Ev "^${pattern}=" "$ENV_FILE" >"$TMP/env" || true
cat >>"$TMP/env" <<ENV
ENTRA_TENANT_ID=$TENANT_ID
PORTAL_CLIENT_ID=$PORTAL_APP_ID
PORTAL_CLIENT_SECRET='$PORTAL_SECRET'
PATRON_API_CLIENT_ID=$PATRON_API_APP_ID
PATRON_API_CLIENT_SECRET='$PATRON_API_SECRET'
JOB_CLIENT_ID=$JOB_APP_ID
JOB_CLIENT_SECRET='$JOB_SECRET'
PATRON_API_SCOPES="api://$PATRON_API_APP_ID/Patron.Read api://$PATRON_API_APP_ID/Patron.Manage"
PATRON_API_APP_SCOPE=api://$PATRON_API_APP_ID/.default
ENV
mv "$TMP/env" "$ENV_FILE"
chmod 600 "$ENV_FILE"

log "Done. IDs and secrets written to .env"
echo "   Portal      $PORTAL_APP_ID"
echo "   Patron API  $PATRON_API_APP_ID  (api://$PATRON_API_APP_ID)"
echo "   Notices job $JOB_APP_ID"
