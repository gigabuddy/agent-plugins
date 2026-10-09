/**
 * The Gigabuddy mod's state contract (decision:FWFiBJHe8lPw): the tool prompts
 * the session is waiting on, drawn in the band above the prompt.
 */

export type GigabuddyApproval = {
  /** The call being decided (`tool_use_id`). */
  id: string;
  /** The tool, as the model names it. */
  tool: string;
  /** One line of its input (a command, a path) for the band. */
  summary: string;
  /** The consent request Gigabuddy holds for it. */
  requestId: string;
};

declare module 'claude-code' {
  interface PluginState {
    gigabuddy: { approvals: GigabuddyApproval[] };
  }
}
