import type { MessageInitShape } from '@bufbuild/protobuf'
import type { ModelCatalogSchema } from '../gen/models_pb.ts'
import type { HostCatalog } from './catalog.ts'

/** Keep upstream provider groups, order, display names and model-specific effort IDs. */
export function catalogFrame(catalog: HostCatalog): MessageInitShape<typeof ModelCatalogSchema> {
  return {
    defaultSelection: catalog.default,
    routableProviders: catalog.routableProviders,
    failures: catalog.failures,
    groups: catalog.groups.map(({ id, name, models }) => ({
      id, name, models: models.map(({ id, name, description, reasoning, badge }) => ({
        id, name, description, efforts: reasoning?.efforts, defaultEffort: reasoning?.defaultEffort,
        badgeText: typeof badge?.text === 'string' ? badge.text : undefined,
        badgeTranslations: typeof badge?.text === 'object' ? badge.text : undefined,
        badgeTone: badge?.tone,
      })),
    })),
  }
}
