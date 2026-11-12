export interface Selection {
  provider: string
  model: string
  reasoningEffort?: string
}

interface CatalogEntry {
  id: string
  name: string
  description?: string
  badge?: { text: string | Record<string, string>; tone: string }
  reasoning?: { efforts: { id: string; name: string; description?: string }[]; defaultEffort?: string }
}

export interface HostCatalog {
  default: Selection
  routableProviders: string[]
  groups: { id: string; name: string; models: CatalogEntry[] }[]
  failures: { id: string; name: string; message: string }[]
}
