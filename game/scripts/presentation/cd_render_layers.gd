class_name CdRenderLayers
extends RefCounted
## Shared native geometry is rendered from two matched cameras. Surface depth
## applies to the main world; billboards use wall/door depth in their own pass.
const WALLS := 1
const SURFACES := 2
const BILLBOARDS := 4
const BILLBOARD_OCCLUDERS := 8
