# `nix run .#push-atticd -- TAG` — build attic-server-image and push it to
# BOTH Alibaba container registries: SG is the canonical one, the JP cluster
# pulls from its own Tokyo registry and ACR EE Basic has no cross-region
# sync. Mirrors python-utils-algo's push-ray-image: temporary CR tokens are
# minted with the aliyun CLI, credentials come from
# ALICLOUD_ACCESS_KEY_ID/ALICLOUD_ACCESS_KEY_SECRET when set, else the
# default aliyun profile provisioned on dev hosts. The RAM user needs
# cr:GetAuthorizationToken on both instances; the Tokyo push goes through the
# internet endpoint, which is ACL-gated (`acr_push=True` on the host in
# deploy-cn-infra's dev_machines.py).
#
# TAG must match the image tag deploy-cn-infra references for atticd
# (deploy_core/ali/attic/setup.py: ATTIC_IMAGE_TAG or a per-cluster
# image_tag). Re-running is cheap: layers already in a registry are
# deduplicated by skopeo. Linux-only — the image is x86_64-linux.
{ lib, ... }:
{
  perSystem = { pkgs, self', ... }: lib.mkIf pkgs.stdenv.isLinux {
    apps.push-atticd = {
      type = "app";
      program = let
        script = pkgs.writeShellApplication {
          name = "push-atticd";
          runtimeInputs = [ pkgs.skopeo pkgs.jq pkgs.aliyun-cli ];
          text = ''
            if [ $# -ne 1 ]; then
              echo "usage: push-atticd TAG (e.g. defy1902-20260902)" >&2
              exit 1
            fi
            TAG="$1"
            # dockerTools.buildImage output: a docker-archive tarball, built
            # (or taken from the store) when this app is evaluated.
            ARCHIVE=${self'.packages.attic-server-image}

            NS="defy-adhoc"
            REPO="atticd"

            SG_VPC="dt-common-m-registry-vpc.ap-southeast-1.cr.aliyuncs.com"
            SG_INTERNET="dt-common-m-registry.ap-southeast-1.cr.aliyuncs.com"
            SG_INSTANCE_ID="cri-xjx3oy0nbrs5amlo"
            SG_REGION="ap-southeast-1"

            JP_HOST="defy-common-registry.ap-northeast-1.cr.aliyuncs.com"
            JP_INSTANCE_ID="cri-2eyx77nbeuhjr1bh"
            JP_REGION="ap-northeast-1"

            # The VPC endpoint resolves only through the SG VPC's private zone.
            if getent hosts "$SG_VPC" >/dev/null 2>&1; then
              SG_HOST="$SG_VPC"
            else
              SG_HOST="$SG_INTERNET"
            fi

            creds_args=()
            if [ -n "''${ALICLOUD_ACCESS_KEY_ID:-}" ]; then
              creds_args=(--access-key-id "''${ALICLOUD_ACCESS_KEY_ID}" --access-key-secret "''${ALICLOUD_ACCESS_KEY_SECRET}")
            fi

            cr_token() { # instance-id region
              aliyun cr GetAuthorizationToken --InstanceId "$1" --region "$2" "''${creds_args[@]}" \
                | jq -r '.AuthorizationToken'
            }

            push() { # host instance-id region
              local host="$1" instance_id="$2" region="$3" token
              echo "== pushing $host/$NS/$REPO:$TAG"
              token=$(cr_token "$instance_id" "$region")
              skopeo --insecure-policy copy \
                --dest-creds "cr_temp_user:$token" \
                "docker-archive:$ARCHIVE" \
                "docker://$host/$NS/$REPO:$TAG"
            }

            push "$SG_HOST" "$SG_INSTANCE_ID" "$SG_REGION"
            push "$JP_HOST" "$JP_INSTANCE_ID" "$JP_REGION"

            echo "done: $NS/$REPO:$TAG is in both registries."
          '';
        };
      in "${script}/bin/push-atticd";
    };
  };
}
