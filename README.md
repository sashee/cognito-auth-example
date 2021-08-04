# Example app to show how Cognito tokens work

## Deploy

Requirements: Terraform set up with an AWS account, npm

* ```terraform init```
* ```terraform apply```

## Usage

* go to the URL
* sign up with a user (for example ```test```/```Password1]```, to conform to the password policy)
* you'll see the Cognito user id and that you have tokens
* use "Refresh token" to generate a new set of access keys
* you'll see the status of each token
  * ```userInfo```: result for the [USERINFO endpoint](https://docs.aws.amazon.com/cognito/latest/developerguide/userinfo-endpoint.html)
  * ```api access_token```: API check for the access token
  * ```api id_token```: API check for the id token
* use "Revoke token" to send a revocation to the [REVOCATION endpoint](https://docs.aws.amazon.com/cognito/latest/developerguide/revocation-endpoint.html)

## Cleanup

* ```terraform destroy```
