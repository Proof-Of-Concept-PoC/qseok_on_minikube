echo 'executing "9_qliksense.sh" ...'
#
echo 'Adding stable and edge repo from qlik.bintray.com'
helm repo add qlik-stable https://qlik.bintray.com/stable
helm repo add qlik-edge https://qlik.bintray.com/edge
helm init
helm repo update
#
echo 'installing stable "qliksense"'
#
cp ~/keycloak/qliksense-template.yaml ~/qliksense.yaml
# indent the publickey by 12 spaces and append to qliksense.yaml
cat ~/api/public.key|sed 's/\(.*\)/            \1/'>>~/qliksense.yaml
#
echo 'creating charts as templates (helm-free install)'
mkdir ~/charts
helm fetch --repo http://qlik.bintray.com/stable/ qliksense-init --untar --untardir ~/charts 
helm fetch --repo http://qlik.bintray.com/stable/ qliksense --untar --untardir ~/charts # --version 1.8.150 
mkdir ~/manifests
helm template --output-dir ~/manifests --name qlikinit ~/charts/qliksense-init/ 
helm template --output-dir ~/manifests --name qlik ~/charts/qliksense/ --values ~/qliksense.yaml 
#
echo 'installing qliksense-init from qlik-stable repo using helm ...'
helm upgrade --install qlikinit qlik-stable/qliksense-init 
helm upgrade --install qlik qlik-stable/qliksense -f ~/qliksense.yaml

#echo 'installing qliksense from manifest folder'
#kubectl apply --recursive --filename ~/manifests/qliksense --validate=false
#
bash /vagrant/sh/waitforpods.sh 7200 30
#
echo 'adding ingress for keycloak'
kubectl create -f ~/keycloak/keycloak-ingress.yaml

echo 'patching edge-auth deployment with NODE_TLS_REJECT_UNAUTHORIZED=0 and hosts entry'
kubectl patch deployment qlik-edge-auth -p '{"spec":{"template":{"spec":{"containers":[{"name":"edge-auth", "env":[{"name":"NODE_TLS_REJECT_UNAUTHORIZED","value":"0"}]}]}}}}'
kubectl exec $(kubectl get pod -o=name --selector app=edge-auth) env|grep TLS
kubectl patch deployment qlik-edge-auth -p '{"spec":{"template":{"spec":{"hostAliases":[{"hostnames":["elastic.example"],"ip":"192.168.56.234"}]}}}}'
kubectl exec $(kubectl get pod -o=name --selector app=edge-auth) cat /etc/hosts

#kubectl delete -f ~/manifests/qliksense/charts/edge-auth/templates/deployment.yaml
#kubectl create -f ~/manifests/qliksense/charts/edge-auth/templates/deployment.yaml --validate=false

# create a JWT token for admin user with my nodejs app
BEARER=$(nodejs ~/api/createjwt.js admin)
echo "JWT user token is:"
echo "$BEARER"

# wait until qlik sense is ready on https
HOST=https://192.168.56.234
STARTLOOP=$(date)
until $(curl --insecure --output /dev/null --connect-timeout 5 --max-time 6 --head \
--fail $HOST/api/v1/users -H "Authorization: Bearer $BEARER"); do
    echo "Waiting for response at $HOST since $STARTLOOP."
    sleep 30
done
#
TENANT=$(curl --insecure -s \
  -X GET "$HOST/api/v1/users" \
  -H "Authorization: Bearer $BEARER"|jq '.data[0].tenantId' -r)
#
echo "You are tenant $TENANT"
# get the license file and apply it
SITELICENSE=$(cat ~/api/sitelicense.txt)
curl --insecure -s \
  -X PUT "$HOST/api/v1/tenants/$TENANT/licenseDefinition" \
  -H "Authorization: Bearer $BEARER" \
  -H "Content-Type: application/json" \
  -d '{"key":"$SITELICENSE"}'
echo ""
#
curl --insecure \
  -X GET "$HOST/api/v1/licenses/overview" \
  -H "Authorization: Bearer $BEARER" \
  -H "Content-Type: application/json"
echo ""
#

