# MakerLibrary3D v4.11 — Member Experience

This release adds member-owned Favorites, Recently Viewed and My Downloads experiences.

## Design

- Favorites reuse Manyfold's existing per-user special liked list.
- Recently Viewed is stored once per member/model with a view counter and latest timestamp.
- Successful archive and individual-file downloads create member-owned download events.
- Every displayed model remains constrained by the existing Pundit model scope and membership-plan library entitlements.
- Members may clear their own viewing or download history.
- Database foreign keys remove activity automatically when its user or model is deleted.
- Existing storage, ingestion and Azure/SMB mounts are not changed.

## Release gates

- Migration against disposable PostgreSQL
- Member authentication and entitlement isolation
- Favorite visibility
- View tracking and de-duplication
- Archive and individual-file download tracking
- Personal history deletion
- Cross-member privacy
- Dashboard and route rendering
- Production job/HTTP/storage propagation gates
- Automatic rollback
