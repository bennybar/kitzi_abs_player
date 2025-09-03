import express from 'express';
import cors from 'cors';
import { Low } from 'lowdb';
import { JSONFile } from 'lowdb/node';

const app = express();
app.use(cors());
app.use(express.json());

// Simple JSON DB using lowdb
const dbFile = new JSONFile('./db.json');
const db = new Low(dbFile, { users: {}, books: {} });
await db.read();
await db.write();

// Middleware: mock auth (reads bearer token but doesn't validate)
app.use((req, res, next) => {
  const auth = req.headers.authorization || '';
  // In production, validate token and set req.user.id accordingly
  // For demo, use a fixed user or from header X-Debug-User
  const debugUser = req.headers['x-debug-user'];
  req.user = { id: debugUser || 'demo-user' };
  next();
});

// GET /api/books/recent?limit=4
app.get('/api/books/recent', async (req, res) => {
  try {
    const limit = Math.max(1, Math.min(20, parseInt(req.query.limit) || 4));
    const userId = req.user.id;
    const user = db.data.users[userId] || { recent: [] };
    const ids = user.recent.slice(0, limit);

    const result = ids
      .map((id) => db.data.books[id])
      .filter(Boolean);

    res.json(result);
  } catch (e) {
    console.error('Error in GET /api/books/recent', e);
    res.status(500).json({ error: 'Failed to fetch recent books' });
  }
});

// POST /api/books/:bookId/played
app.post('/api/books/:bookId/played', async (req, res) => {
  try {
    const userId = req.user.id;
    const { bookId } = req.params;
    const { book } = req.body || {};

    if (!db.data.users[userId]) db.data.users[userId] = { recent: [] };
    const recent = db.data.users[userId].recent;

    // Upsert book details (for demo purposes only)
    if (book && book.id) {
      db.data.books[book.id] = book;
    }

    // Move to front, unique
    const idx = recent.indexOf(bookId);
    if (idx !== -1) recent.splice(idx, 1);
    recent.unshift(bookId);

    // Cap list
    if (recent.length > 20) recent.length = 20;

    await db.write();
    res.json({ success: true });
  } catch (e) {
    console.error('Error in POST /api/books/:bookId/played', e);
    res.status(500).json({ error: 'Failed to record play event' });
  }
});

// Demo endpoint to seed a book
app.post('/api/books/seed', async (req, res) => {
  const book = req.body;
  if (!book || !book.id) return res.status(400).json({ error: 'Missing book.id' });
  db.data.books[book.id] = book;
  await db.write();
  res.json({ success: true });
});

const port = process.env.PORT || 3001;
app.listen(port, () => {
  console.log(`Play history server running on http://localhost:${port}`);
});


