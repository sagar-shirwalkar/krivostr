/**
 * IndexedDB event cache.
 *
 * The browser's copy of the durable local store. The Haskell bridge keeps the
 * authoritative one; this exists so a reload has something to render before the
 * network answers, and so the feed can show history offline.
 *
 * Mirrors the retention policy in `Krivostr.Store`: 30 days for ordinary
 * public events, and never evict the kinds that carry durable private state.
 */

import { NostrEvent, verifyEvent } from './event';

const DB_NAME = 'krivostr';
const DB_VERSION = 1;
const STORE = 'events';
const BY_CREATED_AT = 'by_created_at';

/** Seconds. */
const RETENTION = 30 * 24 * 60 * 60;

/**
 * Kinds kept regardless of age, matching `persistentKinds` in
 * `Krivostr.Store`:
 *   0     metadata
 *   3     follow list
 *   4     direct message
 *   1059  our own events (NIP-59 gift wrap is 1059 too, also durable)
 *   10002 relay list
 */
const PERSISTENT_KINDS: ReadonlySet<number> = new Set([0, 3, 4, 1059, 10002]);

let dbPromise: Promise<IDBDatabase> | null = null;

const promisify = <T>(req: IDBRequest<T>): Promise<T> =>
  new Promise<T>((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });

const openDb = (): Promise<IDBDatabase> =>
  new Promise<IDBDatabase>((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) {
        const store = db.createObjectStore(STORE, { keyPath: 'id' });
        // Newest-first listing comes straight off this index, so `all()` never
        // has to sort the whole store in memory.
        store.createIndex(BY_CREATED_AT, 'created_at');
      }
    };
    req.onsuccess = () => {
      const db = req.result;
      // The test suite deletes the database between cases, and a real user can
      // clear site data. Either way the cached handle is dead, so drop it
      // instead of handing out a connection to a deleted database.
      db.onversionchange = () => {
        db.close();
        dbPromise = null;
      };
      db.onclose = () => {
        dbPromise = null;
      };
      resolve(db);
    };
    req.onerror = () => reject(req.error);
    req.onblocked = () =>
      reject(new Error(`cache: opening ${DB_NAME} is blocked by another connection`));
  });

/** The shared connection, opened on first use. */
const db = (): Promise<IDBDatabase> => {
  if (!dbPromise) {
    dbPromise = openDb().catch((e) => {
      dbPromise = null;
      throw e;
    });
  }
  return dbPromise;
};

const tx = async <T>(
  mode: IDBTransactionMode,
  body: (store: IDBObjectStore) => Promise<T>,
): Promise<T> => {
  const conn = await db();
  const t = conn.transaction(STORE, mode);
  // Start the request before awaiting anything else: an IndexedDB transaction
  // auto-commits as soon as the microtask queue drains without a pending
  // request, so awaiting first would silently close it.
  const result = body(t.objectStore(STORE));
  await new Promise<void>((resolve, reject) => {
    t.oncomplete = () => resolve();
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error);
  });
  return result;
};

/**
 * Insert or replace by id — but only for whole events. A forged event is
 * refused (false) rather than stored: the cache is the browser's durable
 * memory, and unverified bytes must not survive a restart in it.
 */
export const put = async (e: NostrEvent): Promise<boolean> => {
  if (!(await verifyEvent(e))) return false;
  await tx('readwrite', async (store) => {
    await promisify(store.put(e));
  });
  return true;
};

/** The event with this id, or undefined. */
export const get = async (id: string): Promise<NostrEvent | undefined> => {
  const conn = await db();
  const t = conn.transaction(STORE, 'readonly');
  const found = await promisify(t.objectStore(STORE).get(id));
  return found as NostrEvent | undefined;
};

/** Every cached event, newest first. */
export const all = async (): Promise<NostrEvent[]> => {
  const conn = await db();
  const t = conn.transaction(STORE, 'readonly');
  const index = t.objectStore(STORE).index(BY_CREATED_AT);
  const rows: NostrEvent[] = [];
  await new Promise<void>((resolve, reject) => {
    // 'prev' walks the index backwards, which is the newest-first order.
    const req = index.openCursor(null, 'prev');
    req.onsuccess = () => {
      const cursor = req.result;
      if (cursor) {
        rows.push(cursor.value as NostrEvent);
        cursor.continue();
      } else {
        resolve();
      }
    };
    req.onerror = () => reject(req.error);
  });
  return rows;
};

/** Total number of cached events. */
export const count = async (): Promise<number> => {
  const conn = await db();
  const t = conn.transaction(STORE, 'readonly');
  return promisify(t.objectStore(STORE).count());
};

/**
 * Delete public events older than the retention window. Returns how many went.
 */
export const evictExpired = async (now?: number): Promise<number> => {
  const cutoff = (now ?? Date.now() / 1000) - RETENTION;
  const conn = await db();
  const t = conn.transaction(STORE, 'readwrite');
  const store = t.objectStore(STORE);
  const doomed: string[] = [];

  await new Promise<void>((resolve, reject) => {
    const req = store.openCursor();
    req.onsuccess = () => {
      const cursor = req.result;
      if (!cursor) {
        resolve();
        return;
      }
      const e = cursor.value as NostrEvent;
      if (e.created_at < cutoff && !PERSISTENT_KINDS.has(e.kind)) {
        doomed.push(e.id);
      }
      cursor.continue();
    };
    req.onerror = () => reject(req.error);
  });

  for (const id of doomed) {
    await promisify(store.delete(id));
  }

  await new Promise<void>((resolve, reject) => {
    t.oncomplete = () => resolve();
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error);
  });
  return doomed.length;
};

/** Drop everything. Used by tests and by "clear local data". */
export const clear = async (): Promise<void> => {
  await tx('readwrite', async (store) => {
    await promisify(store.clear());
  });
};
