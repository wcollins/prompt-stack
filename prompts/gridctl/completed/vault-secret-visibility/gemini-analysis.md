# Gemini Analysis: Vault Secret Visibility Implementation

After evaluating the project `gridctl`, I've identified several areas where the implementation of the "Vault Secret Visibility" feature can be refined to better integrate with the existing codebase and state management patterns.

## Summary of Findings

1.  **State Management for Vault Visibility**: The current `showVault` state is local to `Header.tsx`. To support opening the vault panel from `Sidebar.tsx`, this state should be moved to a global store, preferably `useUIStore.ts`.
2.  **Vault Panel Filtering**: The `VaultPanel` component currently lacks a mechanism for filtering by variable set. To support the "filtered context" requirement, `VaultPanel` needs to be extended with a `filterSet` prop and state.
3.  **Vault Locked Handling**: The backend guidance for `handleStackSecretsMap` correctly identifies that set membership and auto-injected key enumeration are unavailable when the vault is locked. This should be explicitly handled in the frontend to avoid confusing users.

## Recommended Prompt Updates

### 1. Update "Key Files to Understand"

Add the following files to the list:
- `web/src/components/layout/Header.tsx`: Where `showVault` state is currently managed.
- `web/src/components/vault/VaultPanel.tsx`: Component that needs to support filtering and visibility control.
- `web/src/stores/useUIStore.ts`: Where the new global vault state should be added.

### 2. Refine State Management Strategy

The prompt should explicitly recommend moving the vault visibility state from `Header.tsx` to `useUIStore.ts`.

**Updated Architecture Guidance (Frontend)**:
- Move `showVault` state from `Header.tsx` to `useUIStore.ts` (e.g., `vaultOpen: boolean`, `setVaultOpen: (open: boolean) => void`).
- Add a `vaultFilterSet: string | null` field to `useUIStore.ts` to support filtered context.
- Update `Sidebar.tsx` to use these new store actions when a set name is clicked.

### 3. Vault Panel Extension

The `VaultPanel.tsx` component should be updated to:
1. Use `useUIStore` to manage its visibility (or receive it as a prop from a higher-level component that uses the store).
2. Accept a `filterSet` prop (or use `vaultFilterSet` from the store) to automatically filter the secrets list upon opening.

### 4. Backend Edge Case: Locked Vault and Auto-injection

The backend `handleStackSecretsMap` should return the list of `autoInjectedSets` (from stack config) even if the vault is locked, but the `keyToSet` mapping will naturally be incomplete. The frontend should handle this by showing those sets with a "membership unavailable" indicator.

---

Overall, the feature is well-scoped and provides high value with minimal risk. These updates will ensure a more robust and consistent implementation across the gridctl stack.
