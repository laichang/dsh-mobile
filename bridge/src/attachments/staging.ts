/**
 * Attachments (ARCHITECTURE D95): put the parts of one upload together, check its size and its
 * SHA-256, and keep the file until a CreateTask names it. One `UploadStaging` per connection, so
 * a dropped connection drops its uploads; the app sends them again.
 */
import { createHash } from 'node:crypto'

export const ATTACHMENTS_CAPABILITY = 'attachments.v1'
/** Data bytes in one UploadChunk: one Frame stays well under Noise's 65535-byte message. */
export const PART_SIZE = 48 * 1024
/** Largest file the bridge takes. DSH's own image limit is 50 MiB; the app sends a JPEG. */
export const MAX_UPLOAD_BYTES = 20 * 1024 * 1024
/** Uploads one connection can hold at a time (staged and in progress). */
export const MAX_UPLOADS_PER_CONNECTION = 4
/** The image types DSH takes in a prompt (`ImageMediaType` in @deepseek-ai/dsh-attachment). */
export const IMAGE_MEDIA_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'] as const

/** A complete, checked file. */
export interface StagedImage {
  name: string
  mediaType: string
  data: Uint8Array
}

/** A refusal with a stable code for `Error.code`. */
export class UploadError extends Error {
  constructor(readonly code: string, message: string) { super(message) }
}

interface Upload {
  name: string
  mediaType: string
  size: number
  sha256: Uint8Array
  parts: Uint8Array[]
  received: number
  staged: boolean
}

export class UploadStaging {
  private readonly uploads = new Map<string, Upload>()

  begin(request: { uploadId: string; mediaType: string; name: string; size: bigint; sha256: Uint8Array }): number {
    const { uploadId, mediaType } = request
    if (!uploadId) throw new UploadError('upload/invalid', 'The upload has no id.')
    if (this.uploads.has(uploadId)) throw new UploadError('upload/invalid', 'This upload id is in use.')
    if (this.uploads.size >= MAX_UPLOADS_PER_CONNECTION) {
      throw new UploadError('upload/too-many', `Send at most ${MAX_UPLOADS_PER_CONNECTION} attachments at a time.`)
    }
    if (!(IMAGE_MEDIA_TYPES as readonly string[]).includes(mediaType)) {
      throw new UploadError('upload/media-type', `The host takes ${IMAGE_MEDIA_TYPES.join(', ')}, not ${mediaType || 'no type'}.`)
    }
    if (request.size === 0n) throw new UploadError('upload/invalid', 'The file is empty.')
    if (request.size > BigInt(MAX_UPLOAD_BYTES)) {
      throw new UploadError('upload/too-large', `The file is larger than ${MAX_UPLOAD_BYTES / 1024 / 1024} MiB.`)
    }
    if (request.sha256.length !== 32) throw new UploadError('upload/invalid', 'The SHA-256 must be 32 bytes.')
    this.uploads.set(uploadId, {
      name: request.name || 'photo', mediaType, size: Number(request.size), sha256: request.sha256,
      parts: [], received: 0, staged: false,
    })
    return 0
  }

  chunk(request: { uploadId: string; index: number; data: Uint8Array }): number {
    const upload = this.open(request.uploadId)
    if (request.index !== upload.parts.length) {
      this.uploads.delete(request.uploadId)
      throw new UploadError('upload/missing-part', `Expected part ${upload.parts.length}, got part ${request.index}.`)
    }
    if (request.data.length === 0 || request.data.length > PART_SIZE) {
      this.uploads.delete(request.uploadId)
      throw new UploadError('upload/invalid', `A part has 1 to ${PART_SIZE} bytes.`)
    }
    if (upload.received + request.data.length > upload.size) {
      this.uploads.delete(request.uploadId)
      throw new UploadError('upload/too-large', 'The parts are larger than the declared size.')
    }
    upload.parts.push(request.data)
    upload.received += request.data.length
    return upload.received
  }

  end(uploadId: string): void {
    const upload = this.open(uploadId)
    if (upload.received !== upload.size) {
      this.uploads.delete(uploadId)
      throw new UploadError('upload/missing-part', `Received ${upload.received} of ${upload.size} bytes.`)
    }
    const hash = createHash('sha256')
    for (const part of upload.parts) hash.update(part)
    if (!Buffer.from(upload.sha256).equals(hash.digest())) {
      this.uploads.delete(uploadId)
      throw new UploadError('upload/hash-mismatch', 'The file does not match its SHA-256.')
    }
    upload.staged = true
  }

  /** Removes and returns the staged files, in order. Refuses all of them if one is not staged. */
  take(uploadIds: readonly string[]): StagedImage[] {
    if (new Set(uploadIds).size !== uploadIds.length) throw new UploadError('upload/invalid', 'An upload is named twice.')
    for (const id of uploadIds) {
      if (!this.uploads.get(id)?.staged) throw new UploadError('upload/unknown', 'The attachment is not on the host. Send it again.')
    }
    return uploadIds.map((id) => {
      const upload = this.uploads.get(id)!
      this.uploads.delete(id)
      return { name: upload.name, mediaType: upload.mediaType, data: Buffer.concat(upload.parts) }
    })
  }

  private open(uploadId: string): Upload {
    const upload = this.uploads.get(uploadId)
    if (!upload) throw new UploadError('upload/unknown', 'No upload with this id. Begin it first.')
    if (upload.staged) throw new UploadError('upload/invalid', 'This upload is complete.')
    return upload
  }
}
