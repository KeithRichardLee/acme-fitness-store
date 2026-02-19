#!/usr/bin/env bash
set -euo pipefail

# ==================================================================================================
# ACME Fitness Store — per-space Tanzu Platform deployment
# ==================================================================================================
# Assumes:
#   - You are already logged in (cf login) against Hub (not fundation API)
#     eg cf login -a tanzu-hub.keithlee.ie
#   - Updated the four variables below
#   - Have Postgres, Valkey, GenAI, Application Services, SSO services available in the marketplace
# ==================================================================================================

AppsDomain="apps.tanzu.keithlee.ie"
OrgGroup="acme-fitness-org"
FoundationGroup="prod-fdn-emea"
ChatModel="chat-and-tools-model"
EmbeddingModel="embedding-model" 

# ────────────────────────────────────────────────────────────
# 1. Create org group and space groups
# ────────────────────────────────────────────────────────────
echo "=== Creating org group ==="
cf create-org-group $OrgGroup --fg $FoundationGroup
cf target -o $OrgGroup 

echo "=== Creating spaces ==="
cf create-space-group acme-shared-services-space 
cf create-space-group acme-assist-space          
cf create-space-group acme-cart-space            
cf create-space-group acme-catalog-space         
cf create-space-group acme-identity-space        
cf create-space-group acme-order-space           
cf create-space-group acme-payment-space         
cf create-space-group acme-shopping-space        

# ────────────────────────────────────────────────────────────
# 2. Shared services  (acme-shared-services-space)
# ────────────────────────────────────────────────────────────
echo "=== Enabling service instance sharing ==="
cf enable-feature-flag service_instance_sharing

echo "=== Creating shared services ==="
cf target -s acme-shared-services-space

cf create-service p.service-registry standard acme-registry --wait
cf create-service p.config-server standard acme-config -c '{ "git": { "uri": "https://github.com/spring-cloud-services-samples/acme-fitness-store", "label": "config", "searchPaths": "config" } }' --wait
cf create-service p.gateway standard acme-gateway -c '{"sso": { "plan": "uaa", "scopes": ["openid", "profile", "email"] }, "host": "acme-fitness", "cors": { "allowed-origins": ["*"] }}' --wait

echo "=== Sharing services to app spaces ==="
cf share-service acme-registry -s acme-assist-space   -o $OrgGroup 
cf share-service acme-registry -s acme-identity-space -o $OrgGroup 
cf share-service acme-registry -s acme-order-space    -o $OrgGroup 
cf share-service acme-registry -s acme-catalog-space  -o $OrgGroup 
cf share-service acme-registry -s acme-payment-space  -o $OrgGroup 

cf share-service acme-config -s acme-assist-space     -o $OrgGroup 
cf share-service acme-config -s acme-identity-space   -o $OrgGroup 
cf share-service acme-config -s acme-catalog-space    -o $OrgGroup 
cf share-service acme-config -s acme-payment-space    -o $OrgGroup 

cf share-service acme-gateway -s acme-assist-space    -o $OrgGroup 
cf share-service acme-gateway -s acme-cart-space      -o $OrgGroup 
cf share-service acme-gateway -s acme-catalog-space   -o $OrgGroup 
cf share-service acme-gateway -s acme-identity-space  -o $OrgGroup 
cf share-service acme-gateway -s acme-order-space     -o $OrgGroup 
cf share-service acme-gateway -s acme-payment-space   -o $OrgGroup 
cf share-service acme-gateway -s acme-shopping-space  -o $OrgGroup 

# ────────────────────────────────────────────────────────────
# 3. acme-identity-space
# ────────────────────────────────────────────────────────────
echo "=== Deploying acme-identity ==="
cf target -s acme-identity-space

cf create-service p-identity uaa acme-sso --wait

pushd apps/acme-identity
./gradlew assemble
cf push acme-identity --no-start 
cf bind-service acme-identity acme-sso -c '{ "grant_types": ["authorization_code"], "scopes": ["openid"], "authorities": ["openid"], "redirect_uris": ["https://acme-fitness.'"$AppsDomain"'/"], "auto_approved_scopes": ["openid"], "identity_providers": ["uaa"], "show_on_home_page": false }'
cf bind-service acme-identity acme-gateway -c identity-routes.json
cf start acme-identity
popd

# ────────────────────────────────────────────────────────────
# 4. acme-cart-space
# ────────────────────────────────────────────────────────────
echo "=== Deploying acme-cart ==="
cf target -s acme-cart-space

cf create-service p.redis on-demand-cache acme-redis --wait

pushd apps/acme-cart
cf push acme-cart --no-start
cf bind-service acme-cart acme-gateway -c cart-routes.json
cf start acme-cart
popd

# ────────────────────────────────────────────────────────────
# 5. acme-payment-space
# ────────────────────────────────────────────────────────────
echo "=== Deploying acme-payment ==="
cf target -s acme-payment-space

pushd apps/acme-payment
./gradlew assemble
cf push acme-payment --no-start
cf bind-service acme-payment acme-gateway -c pay-routes.json
cf start acme-payment
popd

# ────────────────────────────────────────────────────────────
# 6. acme-catalog-space
# ────────────────────────────────────────────────────────────
echo "=== Deploying acme-catalog ==="
cf target -s acme-catalog-space

cf create-service postgres on-demand-postgres-db acme-postgres --wait

pushd apps/acme-catalog
./gradlew clean assemble
cf push acme-catalog --no-start
cf bind-service acme-catalog acme-gateway -c catalog-routes.json
cf start acme-catalog
popd

# ────────────────────────────────────────────────────────────
# 7. acme-assist-space
# ────────────────────────────────────────────────────────────
echo "=== Deploying acme-assist ==="
cf target -s acme-assist-space

cf create-service postgres on-demand-postgres-db acme-assist-postgres --wait
cf create-service genai $ChatModel acme-genai-chat --wait         
cf create-service genai $EmbeddingModel acme-genai-embed --wait             

pushd apps/acme-assist
./gradlew clean assemble
cf push acme-assist --no-start
cf bind-service acme-assist acme-gateway -c assist-routes.json
cf start acme-assist
popd

# ────────────────────────────────────────────────────────────
# 8. acme-order-space
# ────────────────────────────────────────────────────────────
echo "=== Deploying acme-order ==="
cf target -s acme-order-space

cf create-service postgres on-demand-postgres-db acme-order-postgres --wait

pushd apps/acme-order
dotnet publish -r linux-x64
cf push acme-order --no-start
cf bind-service acme-order acme-gateway -c order-routes.json
cf start acme-order
popd

# ────────────────────────────────────────────────────────────
# 9. acme-shopping-space
# ────────────────────────────────────────────────────────────
echo "=== Deploying acme-shopping ==="
cf target -s acme-shopping-space

pushd apps/acme-shopping-react
npm install
npm run build
cf push acme-shopping --no-start
cf bind-service acme-shopping acme-gateway -c frontend-routes.json
cf start acme-shopping
popd

# ────────────────────────────────────────────────────────────
echo ""
echo "=== Deployment complete ==="
echo ""
echo "App URL : https://acme-fitness.$AppsDomain"