#!/bin/bash

# deploy.sh - build, upload sourcemaps, and deploy or run locally any one or multiple projects
# using ./env-config/*.env for both build-time and runtime environment configuration. Must be
# called with --env parameter that specifies which env-config file to use. A special case is
# --env=local which will run each project's 'run.sh' script instead of deploying to Google App
# Engine (default).
#
# Usage: ./deploy.sh react flask --env=staging
#
# Can be run from any directory. In --env=local mode it will start web servers for ALL projects
# specified on command-line (backends first) and then eventually, upon exit (Ctrl+C), every one
# of them. An error anywhere in the script (e.g. failed deployment or sentry-cli call) should
# make the entire script exit immediately.
#
# All variables in *.env are passed into each projects runtime environment.
# Some variables, however, are special and are additionally used during the build:
#
#   SENTRY_ORG is passed to ./bin/sentry-release.sh and used to specify which Sentry
#   org to create release in.
#
#   <PROJECT>_SENTRY_PROJECT is passed to ./bin/sentry-release.sh and used to specify
#   which Sentry project to create release in.
#
#   <PROJECT>_RELEASE_PACKAGE_NAME is used to create a new Sentry release (prepended to calendar
#   version e.g. 'package-name@22.9.5' )
#
#   <PROJECT>_SOURCEMAPS_URL_PREFIX
#
#   <PROJECT>_SOURCEMAPS_DIR
#
#   <PROJECT>_APP_ENGINE_SERVICE is used to parametrize app.yaml.template for that project and
#   points to the Google App Engine (GAE) "service" to which the project should be deployed.
#   These values should be configured once in production.env and staging.env and never changed
#   again. Obviously, for local.env they are meaningless and not required.
#   e.g.: REACT_APP_ENGINE_SERVICE
#
#   REACT_APP_<PROJECT>_BACKEND besides being passed into React application runtime these are
#   substituted with the values of respective REACT_APP_<PROJECT>_BACKEND_LOCAL when --env=local
#   AND <PROJECT> is included in the list of projects to build from command-line arguments.
#
# MIGRATION NOTE:
#
#   The old .env and app.yaml must now be deleted from ./<project>/ directory. Instead move all the
#   variables to ./env-config/<env>.env and create ./<project>/app.yaml.template with '${SERVICE}' placeholder
#   in place of actual service name. Finally add <PROJECT>_APP_ENGINE_SERVICE=<actual service name> to all the
#   ./env-config/<env>.env files.

set -e # exit immediately if any command exits with a non-zero status
# https://fvue.nl/wiki/Bash:_Error_handling


# Check if user is authenticated with Google Cloud before running deployment
if command -v gcloud &> /dev/null ; then
  if [ "$(gcloud auth print-access-token 2>/dev/null | wc -c)" -le 200 ]; then
    echo "You are not authenticated with Google Cloud. Press any key to authenticate... (browser window may open)"
    read -n 1 -s
    gcloud auth login
  else
    echo "Already authenticated with Google Cloud as $ACTIVE_ACCOUNT."
  fi
else
  echo "'gcloud' command not found. The Google Cloud SDK is required."
  echo "Please install it, ensure 'gcloud' is in your PATH, and log in, then re-run the script."
  exit 1
fi


# use top-level directory (repository root), to ensure this works regardless of current directory
top=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
export PATH="$PATH:$top/bin"

# Parse CLI arguments
projects=""
env=""
for arg in "$@"; do
  if [[ $arg = --env=* ]]; then
    env=$(echo $arg | cut -d '=' -f 2)
    echo "env = $env"
  else
    projects+="$arg "
  fi
done

USAGE="[ERROR] Invalid arguments. Usage e.g.: ./deploy.sh --env=staging react flask"

# Validate CLI arguments
if [[ "$env" == "" || "$projects" == "" ]]; then
  echo "$USAGE";
  exit 1
fi

if [ "$env" == "production" ]; then
  if [ -t 0 ] ; then # shell is interactive
    verify_latest_code.sh
  fi
fi

# Re-order so backends are launched first
be_projects=""
fe_projects=""
for proj in $projects; do
  if [[ $proj =~ ^(flask|express|ruby|spring-boot|aspnetcore|laravel|ruby-on-rails|crons-python)$ ]]; then
    be_projects+="$proj "
  else
    fe_projects+="$proj "
  fi
done
projects="$be_projects $fe_projects"

function cleanup {
  for pid in $run_sh_pids; do
    # each run.sh has it's own cleanup function
    if ps -p $pid > /dev/null; then
      kill $pid 2>/dev/null
    fi
  done
  rm -f $top/*/.app.yaml
  rm -f $top/spring-boot/src/main/appengine/app.yaml
  rm -f $top/spring-boot/src/main/resources/application.properties
  rm -f $top/crons-python/crontab
  rm -f $top/react/config-overrides.js
  if [ "$generated_envs" != "" ]; then
    rm -f $generated_envs # bash only (passed as separate args)
  fi
}
trap cleanup EXIT

run_sh_pids=""
generated_envs=""

for proj in $projects; do # bash only

  echo "|||"
  echo "||| $0: $proj"
  echo "|||"

  # Function to fetch secrets from Google Cloud Secret Manager (uses same name for env var and secret)
  fetch_secrets_to_env() {
    # Check if gcloud is available
    if ! command -v gcloud &> /dev/null; then
      echo "[ERROR] gcloud command not found, skipping secret fetching"
      return 1
    fi

    echo "Fetching secrets from Google Cloud Secret Manager for environment: $env..."

    # Define the list of secrets to fetch - names will be identical in env and Secret Manager
    local secrets=(
      "STATSIG_CLIENT_KEY"
      "STATSIG_SERVER_KEY"
    )

    # Add environment-specific Sentry token
    local sentry_token_name
    case "$env" in
      "production")
        sentry_token_name="SENTRY_AUTH_TOKEN_PROD_DEMO"
        ;;
      "staging")
        sentry_token_name="SENTRY_AUTH_TOKEN_STAGING_TEAM_SE"
        ;;
      "local")
        echo "[INFO] Skipping auth token fetching for local environment"
        ;;
      *)
        echo "[ERROR] Unknown environment '$env'"
        exit 1
    esac

    # Add Sentry token to secrets list if we're in prod/staging
    if [ -n "$sentry_token_name" ]; then
      secrets+=("$sentry_token_name")
    fi

    # Fetch each secret and export it to environment
    for secret_name in "${secrets[@]}"; do
      echo "  Fetching secret $secret_name..."

      # Fetch the secret value
      local value
      value=$(gcloud secrets versions access latest --secret="$secret_name" --project=sales-engineering-sf 2>/dev/null)

      if [ $? -ne 0 ]; then
        echo "[ERROR] Failed to fetch secret '$secret_name', skipping"
        exit 1
      else
        # For Sentry tokens, always export as SENTRY_AUTH_TOKEN regardless of secret name
        if [[ "$secret_name" == "SENTRY_AUTH_TOKEN"* ]]; then
          export "SENTRY_AUTH_TOKEN=$value"
          echo "  Successfully set SENTRY_AUTH_TOKEN"
        else
          export "$secret_name=$value"
          echo "  Successfully set $secret_name"
          # If the project is React, also export it prefixed for build-time embedding
          if [[ "$proj" == "react" && "$secret_name" == "STATSIG_CLIENT_KEY" ]]; then
            export "REACT_APP_STATSIG_CLIENT_KEY=$value"
            echo "  Also exported as REACT_APP_STATSIG_CLIENT_KEY for React build"
          fi
        fi
      fi
    done
  }

  # Fetch secrets before validating project
  fetch_secrets_to_env

  validate_project.sh $top/$proj

  cd $top/$proj

  # React "bakes in" env variables (exported from calling shell) as well as contents
  # of .env into the build, whereas Express/Flask need .env at runtime
  # We dynamically generate a temporary .env from env-config/$env.env.
  # env.sh among other things validates env vars listed in the project's validate_env.list
  # via bin/validate_dotenv.sh -> bin/validate_env.sh.
  generated_envs+="$(../env.sh $env) "


  # We do this because 1) we need RELEASE that's generated in env.sh 2) we need *_APP_*_BACKEND
  # 3) some projects may require env variables instead of .env (not the case for react, flask & express)
  # TODO: double check above comment is still correct, we do this 3 times (once here and twice in env.sh)
  # TODO: support spring-boot which seems to use .properties files
  export $(grep -v '^#' .env | sed 's/ #.*//' | xargs)

  echo "Setting project to $PROJECT_ID"
  gcloud config set project $PROJECT_ID

  if [[ "$env" == "local" && "$fe_projects" = *"$proj "* ]]; then
    # Point to local backend http://host:port instead of cloud endpoints for all _built_ BE projects
    # If no backend projects specified in CLI args, keep using cloud (production or staging) BE endpoints.
    for be_proj in $be_projects; do
      if  [ "$proj" == "next" ]; then
        # Next env variables need to start with NEXT_PUBLIC_*
        backend_var=$(var_name.sh NEXT_PUBLIC_%s_BACKEND $be_proj)
      else
        backend_var=$(var_name.sh %s_APP_%s_BACKEND $proj $be_proj)
      fi
      . get_proj_var.sh "%s_LOCAL_PORT" $be_proj # sets $local_port
      echo "" >> .env # in case no newline
      backend_local="http://localhost:$local_port"
      echo "$backend_var=$backend_local" >> .env # append instead of search-replace should be OK
      export "$backend_var=$backend_local"
    done
  fi

  CLOUD_SQL_AUTH_PROXY=172.17.0.1
  if [ "$env" != "local" ]; then
    if [ "$proj" == "aspnetcore" ]; then
      # https://cloud.google.com/sql/docs/postgres/connect-app-engine-flexible
      export DB_HOST="$CLOUD_SQL_AUTH_PROXY"
    elif [ "$proj" == "laravel" ]; then
      # https://cloud.google.com/sql/docs/postgres/connect-app-engine-standard#php
      export DB_HOST="pgsql:dbname=$DB_DATABASE;host=/cloudsql/$DB_CLOUD_SQL_CONNECTION_NAME/"
    fi
  fi

  unset CI # prevents build failing in GitHub Actions
  ./build.sh


  if [[ $proj =~ ^(react|next|vue|flask)$ ]]; then # Suspect Commits now require commits associated w/ release
    if [[ $proj =~ ^(react|next|flask)$ ]]; then
      upload_sourcemaps="false" # using webpack plugin or doesn not apply
    else
      upload_sourcemaps="true"
    fi
    sentry-release.sh $env $RELEASE $upload_sourcemaps
    # NOTE: Sentry may create releases from events even without this step
  fi

  # *** DEPLOY OR RUN ***
  if [ "$env" == "local" ]; then

    if [[ "$be_projects" = *"$proj "* ]]; then
      . get_proj_var.sh "%s_LOCAL_PORT" $proj # sets $local_port
      export LOCAL_PORT="$local_port"
    fi

    ./run.sh &
    pid="$!"
    run_sh_pids+="$pid " # for later cleanup

    if [[ "$projects" != *"$proj " ]]; then # not last one
      sleep 1
      echo "$0: Waiting a few seconds before building next project to make sure this server process doesn't crash..."
      sleep 4
      if ! ps -p $pid > /dev/null
      then
        echo "$0 [ERROR]: $proj/run.sh exited early, must be a crash."
        exit 1
      fi
    fi
  elif [ -f deploy_project.sh ]; then
    if [[ "$proj" =~ ^crons- ]]; then
      . get_proj_var.sh "%s_DEPLOY_DIR" $proj
      escaped_deploy_dir=$(echo "$deploy_dir" | sed 's_/_\\/_g')
      sed -e 's/<CRONSPYTHON_DEPLOY_DIR>/'$escaped_deploy_dir'/g' crontab.template > crontab
    fi
    ./deploy_project.sh
  else

    # Replace ${SERVICE} in app.yaml.template with <PROJECT>_APP_ENGINE_SERVICE
    . get_proj_var.sh "%s_APP_ENGINE_SERVICE" $proj

    if [ "$proj" == "spring-boot" ]; then
      ypath="./src/main/appengine/"
      SERVICE=$app_engine_service SPRINGBOOT_ENV="production" envsubst.sh < $ypath/app.yaml.template > $ypath/app.yaml
      mvn clean package appengine:deploy
    elif [ "$proj" == "aspnetcore" ]; then
      # TODO: envsubst is super easy - this should be the default for all projects
      envsubst.sh < app.yaml.template > .app.yaml
      envsubst.sh < Dockerfile.template > Dockerfile
      gcloud app deploy --version v1 --quiet .app.yaml
      rm Dockerfile
    else
      # all other projects
      SERVICE=$app_engine_service envsubst.sh < app.yaml.template > .app.yaml
      cat .app.yaml
      gcloud app deploy --version v1 --quiet .app.yaml
    fi
  fi
done

if [ "$env" == "local" ]; then
  sleep 1
  echo "Server process(es) are running. Press Ctrl+C to terminate..."
  while true; do sleep 86400; done
fi
