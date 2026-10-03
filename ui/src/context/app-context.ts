import { createContext } from '@lit/context';
import { Signer } from '../nostr/signer';

export interface AppState {
  signer: Signer | null;
  transport: 'bridge' | 'relay';
}

export const appContext = createContext<AppState>('krivostr-app-state');
