/**
 * S14 · the drawer (PLAN.md §5 S14, ARCHITECTURE D54). The phone groups sessions as
 * host › workspace › session. Each `TaskSummary` carries its session's workspace (field 280):
 * the `cwd` that DSH reports for the session, or, until DSH lists it, the directory the phone's
 * CreateTask used. A bridge without `drawer.v1` sends no workspace; the app then shows host › session.
 */
export const DRAWER_CAPABILITY = 'drawer.v1'

/** DSH's own value wins: it is the same for a Web, desktop and phone session in one directory. */
export function sessionWorkspace(dshCwd: string | undefined, known: string | undefined): string | undefined {
  return dshCwd || known || undefined
}
