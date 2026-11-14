#!/usr/bin/env python3
"""Apply the Android ION map-lifetime fix to pinned upstream v4.14.116."""

import subprocess
import sys
from pathlib import Path


EXPECTED_COMMIT = "6d1510d86ef67e5fadb8038671e2ec43416daf7f"
RELATIVE_SOURCE = Path("drivers/staging/android/ion/ion.c")


def replace_once(source: str, before: str, after: str, label: str) -> str:
    count = source.count(before)
    if count != 1:
        raise RuntimeError(f"expected one {label} match, found {count}")
    return source.replace(before, after, 1)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} KERNEL_SOURCE", file=sys.stderr)
        return 2

    root = Path(sys.argv[1]).resolve()
    commit = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()
    if commit != EXPECTED_COMMIT:
        raise RuntimeError(f"expected {EXPECTED_COMMIT}, found {commit}")
    top = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "--show-toplevel"], text=True
    ).strip()
    if Path(top) != root:
        raise RuntimeError(f"unexpected worktree root: {top}")

    source_path = root / RELATIVE_SOURCE
    baseline = subprocess.check_output(
        [
            "git",
            "-C",
            str(root),
            "show",
            f"{EXPECTED_COMMIT}:{RELATIVE_SOURCE.as_posix()}",
        ],
        text=True,
    )
    current = source_path.read_text()
    source = baseline
    source = replace_once(
        source,
        """static void *ion_dma_buf_kmap(struct dma_buf *dmabuf, unsigned long offset)
{
	struct ion_buffer *buffer = dmabuf->priv;

	return buffer->vaddr + offset * PAGE_SIZE;
}

static void ion_dma_buf_kunmap(struct dma_buf *dmabuf, unsigned long offset,
			       void *ptr)
{
}
""",
        """static void *ion_dma_buf_kmap(struct dma_buf *dmabuf, unsigned long offset)
{
	struct ion_buffer *buffer = dmabuf->priv;
	void *vaddr;

	if (!buffer->heap->ops->map_kernel)
		return ERR_PTR(-ENOTTY);
	mutex_lock(&buffer->lock);
	vaddr = ion_buffer_kmap_get(buffer);
	mutex_unlock(&buffer->lock);
	if (IS_ERR(vaddr))
		return vaddr;
	return vaddr + offset * PAGE_SIZE;
}

static void ion_dma_buf_kunmap(struct dma_buf *dmabuf, unsigned long offset,
			       void *ptr)
{
	struct ion_buffer *buffer = dmabuf->priv;

	if (buffer->heap->ops->map_kernel) {
		mutex_lock(&buffer->lock);
		ion_buffer_kmap_put(buffer);
		mutex_unlock(&buffer->lock);
	}
}
""",
        "DMA-BUF kmap/kunmap callbacks",
    )
    source = replace_once(
        source,
        """	void *vaddr;
	struct ion_dma_buf_attachment *a;

	/*
	 * TODO: Move this elsewhere because we don't always need a vaddr
	 */
	if (buffer->heap->ops->map_kernel) {
		mutex_lock(&buffer->lock);
		vaddr = ion_buffer_kmap_get(buffer);
		mutex_unlock(&buffer->lock);
	}
""",
        """	struct ion_dma_buf_attachment *a;
""",
        "begin_cpu_access mapping ownership",
    )
    source = replace_once(
        source,
        """	if (buffer->heap->ops->map_kernel) {
		mutex_lock(&buffer->lock);
		ion_buffer_kmap_put(buffer);
		mutex_unlock(&buffer->lock);
	}

	mutex_lock(&buffer->lock);
	list_for_each_entry(a, &buffer->attachments, list) {
		dma_sync_sg_for_device(a->dev, a->table->sgl, a->table->nents,
""",
        """	mutex_lock(&buffer->lock);
	list_for_each_entry(a, &buffer->attachments, list) {
		dma_sync_sg_for_device(a->dev, a->table->sgl, a->table->nents,
""",
        "end_cpu_access mapping ownership",
    )
    if current == baseline:
        source_path.write_text(source)
    elif current != source:
        raise RuntimeError("ION source has unexpected local changes; refusing to overwrite it")

    changed = subprocess.check_output(
        ["git", "-C", str(root), "diff", "--name-only"], text=True
    ).splitlines()
    if changed != [RELATIVE_SOURCE.as_posix()]:
        raise RuntimeError(f"unexpected changed paths: {changed}")
    cached = subprocess.check_output(
        ["git", "-C", str(root), "diff", "--cached", "--name-only"], text=True
    ).splitlines()
    untracked = subprocess.check_output(
        [
            "git",
            "-C",
            str(root),
            "ls-files",
            "--others",
            "--exclude-standard",
        ],
        text=True,
    ).splitlines()
    if cached or untracked:
        raise RuntimeError(f"unexpected staged or untracked files: {cached + untracked}")
    print(f"Applied Android ION map-lifetime fix to {RELATIVE_SOURCE}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"apply-ion-fix: {error}", file=sys.stderr)
        raise SystemExit(1)
