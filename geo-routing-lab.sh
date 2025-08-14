#!/bin/bash
# Google Cloud DNS Geo Routing Lab Automation Script

# ===== CONFIG =====
REGION1="us-east1"
ZONE1="us-east1-b"
REGION2="europe-west1"
ZONE2="europe-west1-b"
REGION3="asia-south1"
ZONE3="asia-south1-b"

# ===== STEP 1: Enable APIs =====
gcloud services enable compute.googleapis.com
gcloud services enable dns.googleapis.com

# ===== STEP 2: Configure firewall =====
gcloud compute firewall-rules create fw-default-iapproxy \
--direction=INGRESS \
--priority=1000 \
--network=default \
--action=ALLOW \
--rules=tcp:22,icmp \
--source-ranges=35.235.240.0/20

gcloud compute firewall-rules create allow-http-traffic \
--direction=INGRESS \
--priority=1000 \
--network=default \
--action=ALLOW \
--rules=tcp:80 \
--source-ranges=0.0.0.0/0 \
--target-tags=http-server

# ===== STEP 3: Launch Client VMs =====
gcloud compute instances create us-client-vm --machine-type e2-micro --zone $ZONE1
gcloud compute instances create europe-client-vm --machine-type e2-micro --zone $ZONE2
gcloud compute instances create asia-client-vm --machine-type e2-micro --zone $ZONE3

# ===== STEP 4: Launch Server VMs =====
gcloud compute instances create us-web-vm \
--zone=$ZONE1 \
--machine-type=e2-micro \
--tags=http-server \
--metadata=startup-script="#! /bin/bash
apt-get update
apt-get install apache2 -y
echo 'Page served from: $REGION1' > /var/www/html/index.html
systemctl restart apache2"

gcloud compute instances create europe-web-vm \
--zone=$ZONE2 \
--machine-type=e2-micro \
--tags=http-server \
--metadata=startup-script="#! /bin/bash
apt-get update
apt-get install apache2 -y
echo 'Page served from: $REGION2' > /var/www/html/index.html
systemctl restart apache2"

# ===== STEP 5: Save Internal IPs =====
export US_WEB_IP=$(gcloud compute instances describe us-web-vm --zone=$ZONE1 --format="value(networkInterfaces.networkIP)")
export EUROPE_WEB_IP=$(gcloud compute instances describe europe-web-vm --zone=$ZONE2 --format="value(networkInterfaces.networkIP)")

# ===== STEP 6: Create Private Zone =====
gcloud dns managed-zones create example \
--description=test \
--dns-name=example.com \
--networks=default \
--visibility=private

# ===== STEP 7: Create Geo Routing Policy =====
gcloud dns record-sets create geo.example.com \
--ttl=5 --type=A --zone=example \
--routing-policy-type=GEO \
--routing-policy-data="$REGION1=$US_WEB_IP;$REGION2=$EUROPE_WEB_IP"

# ===== STEP 8: Test Instructions =====
echo "Testing Instructions:"
echo "1. SSH into each client VM:"
echo "   gcloud compute ssh us-client-vm --zone=$ZONE1 --tunnel-through-iap"
echo "   gcloud compute ssh europe-client-vm --zone=$ZONE2 --tunnel-through-iap"
echo "   gcloud compute ssh asia-client-vm --zone=$ZONE3 --tunnel-through-iap"
echo "2. Run: for i in {1..10}; do echo \$i; curl geo.example.com; sleep 6; done"
echo "3. Compare results."

# ===== STEP 9: Cleanup Function =====
cleanup_resources() {
    echo "Deleting all lab resources..."
    gcloud compute instances delete -q us-client-vm --zone $ZONE1
    gcloud compute instances delete -q us-web-vm --zone $ZONE1
    gcloud compute instances delete -q europe-client-vm --zone $ZONE2
    gcloud compute instances delete -q europe-web-vm --zone $ZONE2
    gcloud compute instances delete -q asia-client-vm --zone $ZONE3
    gcloud compute firewall-rules delete -q allow-http-traffic
    gcloud compute firewall-rules delete -q fw-default-iapproxy
    gcloud dns record-sets delete geo.example.com --type=A --zone=example
    gcloud dns managed-zones delete example
}
echo "To cleanup later, run: bash geo-routing-lab.sh cleanup"

if [[ "$1" == "cleanup" ]]; then
    cleanup_resources
fi
