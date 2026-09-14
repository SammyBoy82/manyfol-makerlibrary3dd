# MakerLibrary3D Project State

Updated: 20260914T135454Z

## Production baseline

- Release: v4.9.1
- Manyfold: 0.147.1
- Image: slforge/manyfold-makerlibrary3d:0.147.1-storage-v4.9.1
- Runtime UID/GID: 1500:1500
- Dynamic storage root: /srv/slforge/storage-sources
- Container storage root: /storage-sources
- Mount propagation: rshared
- Storage providers: local, Azure Blob/BlobFuse2, SMB/CIFS and Azure Files
- Storage activity: footer pagination with completed-history clearing
- Azure Files: Windows connection-script import
- Privileged mounts: existing host queue/helper architecture

## Validated Azure Files source

- Display name: Azure_Shared01
- Slug: mainlib01
- Container path: /storage-sources/smb/mainlib01
- Persistent unit: srv-slforge-storage\x2dsources-smb-mainlib01.mount
- Models at acceptance: 15
- ModelFile records at acceptance: 30

## Operational policy

Root-level STL and 3MF files must be placed in individual model folders
before scanning. Production Azure Blob libraries remain protected unless a
specific maintenance operation is authorized.

## Release recovery

- Release directory: /srv/slforge/releases/makerlibrary3d-v4.9.1-20260914T135454Z
- Rollback: sudo bash /srv/slforge/releases/makerlibrary3d-v4.9.1-20260914T135454Z/rollback.sh
