# Sourced. Every connection -> throwaway oms-test-mysql / oms-test-mongo on oms-test-net.
W=/Users/np1076/dev/spk/owl/.claude/worktrees/oms-laravel-api/SBDEV-2624
ENVS=(-e APP_ENV=testing
  -e DB_HOST=oms-test-mysql -e DB_PORT=3306 -e DB_USERNAME=root -e DB_PASSWORD=owltest -e DB_DATABASE=om1_owltest
  -e LANDLORD_HOST=oms-test-mysql -e LANDLORD_PORT=3306 -e LANDLORD_USERNAME=root -e LANDLORD_PASSWORD=owltest -e LANDLORD_DATABASE=om1_landlord_owltest
  -e REPORTING_HOST=oms-test-mysql -e REPORTING_PORT=3306 -e REPORTING_USERNAME=root -e REPORTING_PASSWORD=owltest -e REPORTING_DATABASE=om1_owltest_reporting
  -e MONGODB_HOST=oms-test-mongo -e MONGODB_PORT=27017 -e REDIS_HOST=127.0.0.1)
RUN_PHP() { docker run --rm --network oms-test-net -v "$W":/app -w /app "${ENVS[@]}" oms-php:8.4 "$@"; }
DC() { docker exec -i oms-test-mysql mysql -uroot -powltest "$@" 2>&1 | grep -v 'Using a password'; }
