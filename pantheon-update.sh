#!/bin/bash

terminus_auth() {
	response=`terminus auth whoami`
	if [ "$response" == "" ]; then
		echo "You are not authenticated with Terminus..."
		terminus auth login
		if [ $? -eq 0 ]; then
    		        echo "Login successful!"
		else
    			echo "Login failed. Please re-run the script and try again."
			exit 0
		fi
	else
		read -p "$response.  [y]Continue or [n]login as someone else? [y/n] " login;
		case $login in
			[Yy]* ) ;;
			[Nn]* ) terminus auth logout;
					terminus auth login;;
		esac
	fi
}

step_route()
{
    FRAMEWORK=`terminus site info --site=$SITENAME --field=framework`
    ERRORS='0'
    if [ "$FRAMEWORK" = 'framework: drupal' ]; then
            case $STEP in
                    [start]* ) multidev_drupal_update $SITENAME;;
                    [finish]* ) multidev_finish $SITENAME;;
                    * ) echo "not a valid function."; exit 1;;
            esac
    fi

    if [ "$FRAMEWORK" = 'framework: wordpress' ]; then
            case $STEP in
                    [start]* ) multidev_wordpress_update $SITENAME;;
                    [finish]* ) multidev_finish $SITENAME;;
                    * ) echo "not a valid function."; exit 1;;
            esac
    fi
}

multidev_update_prep() {
	echo "Updating ${FRAMEWORK} site with multidev..."
	MDENV='hotfix-up'

	read -p "Backup prod? [y/n]  " yn
	case $yn in
		[Yy]* ) echo "Creating backup of prod environment for ${SITENAME}... "; 
				terminus site backups create --site=${SITENAME} --env=live;;
	esac
	if [ $? = 1 ]; then
		$((ERRORS++))
		echo "error in backup prod"
	fi

	envExist=`terminus site environments --site=${SITENAME} | grep "${MDENV}"`
	if [ -z "$envExist" ]; then
		echo "Creating multidev hotfix-up enironment..."
		read -p "Pull down db from which environment? (dev/test/live) "	FROMENV
		terminus site create-env --to-env=${MDENV} --from-env=${FROMENV} --site=${SITENAME}
		if [ $? = 1 ]; then
			$((ERRORS++))
			echo "error in creating env"
		fi
	else
		read -p "Multidev hotfix-up environment already exists.  Deploy db from which environment? (dev/test/live/none) " FROMENV
		if [ $FROMENV != 'none' ]; then
			terminus site deploy --site=$SITENAME --env=$MDENV --cc --updatedb --note='Deploy files and db from ${FROMENV} to {$MDENV}.'
		fi
	fi

	echo "The URL for the new environment is http://${MDENV}-${SITENAME}.gotpantheon.com/"

	echo "Switching to sftp connection-mode..."
	terminus site set-connection-mode --env=${MDENV} --site=${SITENAME} --mode=sftp
	if [ $? = 1 ]; then
		$((ERRORS++))
		echo "error in switching to sftp"
	fi

}

multidev_update_errors() {
	if [ $ERRORS != '0' ]; then
		WORD='error was'
		if [ $ERRORS > '1' ]; then
			WORD='errors were'
		fi
		echo "$ERRORS $WORD reported.  Scroll up and look for the red."
	fi
}

multidev_drupal_update() {

	multidev_update_prep

	terminus drush up --no-core=1 --env=${MDENV} --site=${SITENAME}
	if [ $? = 1 ]; then
		$((ERRORS++))
		echo "error in drush up"
		UPFAIL='Drush up failed.'
	fi

	if [ -z "$UPFAIL" ]; then
		echo "Running 'drush updb'..."
		terminus drush updb -y --env=${MDENV} --site=${SITENAME}
		if [ $? = 1 ]; then
			$((ERRORS++))
			echo "error in updb"
			UPDBFAIL='Drush updb failed.'
		fi
		echo "Site's modules have been updated on $MDENV multidev site. Please test it here: http://${MDENV}-${SITENAME}.pantheon.io/"
	fi

	multidev_update_errors

}

multidev_merge() {
	## In this case, 'origin' is Pantheon remote name.  
        git clone $GITURL pantheon-clone_${SITENAME}
        cd pantheon-clone_${SITENAME}
        git fetch --all

        if [ $? -ne 0 ]; then
    echo "git fetch --all failed"
    exit 1
        fi

	git checkout $MDENV
        git pull origin $MDENV
        git checkout master
        git pull origin master

        git checkout develop
        git merge $MDENV
	
	if [ $? -ne 0 ]; then
    echo "Merge failed"
    Timestamp = date +"%Y-%m-%d-%T"
    git merge --abort 2> conflicts.${Timestamp}.txt 
    git reset --hard origin/master
    git clean -df
    exit 1
	fi

	git push origin master
	echo "Pushed to master. Please visit the dev environment to view your updates"
}

multidev_deploy_to_test() {
	read -p "Deploy changes to test environment on Pantheon? [y/n] " DEPLOYTEST
	case $DEPLOYTEST in
		[Yy]* ) read -p "Please provide a note to attach to this deployment to Test: " MESSAGE
						terminus site deploy --site=${SITENAME} --env=test --cc --updatedb --note="$MESSAGE";;
		[Nn]* ) exit 0;;
	esac
}

multidev_deploy_to_live() {
	read -p "Deploy changes to live environment on Pantheon? [y/n] " DEPLOYLIVE
	case $DEPLOYLIVE in
		[Yy]* ) read -p "Please provide a note to attach to this deployment to Live: " MESSAGE
						terminus site deploy --site=${SITENAME} --env=live --cc --updatedb --note="$MESSAGE";;
		[Nn]* ) exit 0;;
	esac
}

multidev_finish() {
	SITE=$1
	MDENV='hotfix-up'
	SITEINFO=`terminus site info --site=${SITENAME} --field=id`
	SITEID=${SITEINFO#*: }
	GITURL="ssh://codeserver.dev.${SITEID}@codeserver.dev.${SITEID}.drush.in:2222/~/repository.git"

    read -p "Please provide git commit message: " MESSAGE
        terminus site code commit --site=${SITENAME} --env=${MDENV} --message="$MESSAGE"
        if [ $? -ne 0 ]; then
    echo "git commit failed"
    exit 1
        fi

    echo "Returning hotfix-up to git connection-mode..."
    terminus site set-connection-mode --env=${MDENV} --mode=git --site=${SITENAME}
    if [ $? -ne 0 ]; then
    echo "Switching connection mode back to git failed."
    exit 1
    fi 
	
	multidev_merge

	read -p "Delete hotfix-up environment? [y/n]  " yn
	case $yn in
		[Yy]* ) terminus site delete-env --site=${SITENAME} --env=${MDENV}
	esac

	multidev_deploy_to_test

	multidev_deploy_to_live
	
	read -p "Delete pantheon-clone folder? [y/n] " yn
	case $yn in 
	      [Yy]*) cd ../; echo "deleting pantheon-clone..."; rm -rf pantheon-clone_${SITENAME}	
	esac

}

multidev_wordpress_update() {
	MDENV='hotfix-up'
	SITE=$1

	multidev_update_prep
	terminus wp plugin update --all=1 --site=$SITENAME --env=$MDENV
	if [ $? = 1 ]; then
		$((ERRORS++))
		echo "error in wp plugin update"
		UPFAIL='WP up failed.'
	else
		echo "Site's plugins have been updated on $MDENV multidev site. Please test it here: http://${MDENV}-${SITENAME}.pantheon.io/"
	fi


}

terminus_auth
echo 'Loading site list'
terminus sites list
read -p 'Type in site name and press [Enter] to start updating: ' SITENAME
STEP='start'
step_route

read -p "Press [Enter] to finish updating ${SITENAME}" 
STEP='finish'
step_route

read -p 'Log out of Terminus? [y/n] ' LOGOUT
  case $LOGOUT in
        [Yy]* ) terminus auth logout

  esac
exit 0
