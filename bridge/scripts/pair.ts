/**
 * Prints a new single-use pairing QR for a running bridge (terminal-first pairing).
 *   DSH_HOME=~/.dsh node lib/scripts/pair.js [--state-dir DIR] [--ttl-minutes 10] [--url-only]
 * The state dir defaults to the bridge's: $DSHM_BRIDGE_STATE_DIR, else $DSH_HOME/dsh-mobile-bridge.
 * --url-only prints just the dshm://pair link (scripts/demo/pairing.sh feeds it to the Simulator).
 */
import { resolveConfig } from '../src/index.ts'
import { renderOffer } from '../src/pairing/announce.ts'
import { requestOffer } from '../src/tls/local-offers.ts'
import { parseOfferURL, offerURL } from '../src/pairing/offer.ts'

const args = process.argv.slice(2)
const flag = (name: string) => {
  const i = args.indexOf(name)
  return i >= 0 ? args[i + 1] : undefined
}
const stateDir = flag('--state-dir') ?? resolveConfig().stateDir
const ttlMinutes = Number(flag('--ttl-minutes') ?? 10)
try {
  const offer = parseOfferURL(await requestOffer(stateDir, ttlMinutes * 60_000))
  console.log(args.includes('--url-only') ? offerURL(offer) : renderOffer(offer))
} catch (error) {
  console.error(`pair: ${error instanceof Error ? error.message : String(error)}`)
  process.exit(1)
}
