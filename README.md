OaDeployer
==========

Deploys OpenAperture via CLI

## Usage
    mix escript.build
    ./oa_deployer <options> <_docker repo url>

### Options
    -a <action>     (build, deploy, or deploy_ecs)
    -s <server_url> OpenAperture manager server url
    -h <hash>       source commit hash
    -n <branch>     _docker repo branch to use