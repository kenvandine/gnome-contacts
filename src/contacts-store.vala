/* -*- Mode: vala; indent-tabs-mode: t; c-basic-offset: 2; tab-width: 8 -*- */
/*
 * Copyright (C) 2011 Alexander Larsson <alexl@redhat.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

using Gtk;
using Folks;
using Gee;
using TelepathyGLib;

public class Contacts.Store : GLib.Object {
  public signal void changed (Contact c);
  public signal void added (Contact c);
  public signal void removed (Contact c);
  public signal void quiescent ();
  public signal void prepared ();

  public signal void eds_persona_store_changed ();

  public IndividualAggregator aggregator { get; private set; }
  public BackendStore backend_store { get; private set; }
  Gee.ArrayList<Contact> contacts;

  public Gee.HashMap<string, Account> calling_accounts;

  public Gee.HashMultiMap<string, string> dont_suggest_link;

  public bool can_call {
    get {
      return this.calling_accounts.size > 0 ? true : false;
    }
  }

  public bool is_quiescent {
    get { return this.aggregator.is_quiescent; }
  }

  public bool is_prepared {
    get { return this.aggregator.is_prepared; }
  }

  public void refresh () {
    foreach (var c in contacts) {
      c.queue_changed (true);
    }
  }

  private bool individual_can_replace_at_split (Individual new_individual) {
    foreach (var p in new_individual.personas) {
      if (p.get_data<bool> ("contacts-new-contact"))
	return false;
    }
    return true;
  }

  private bool individual_should_replace_at_join (Individual old_individual) {
    var c = Contact.from_individual (old_individual);
    return c.get_data<bool> ("contacts-master-at-join");
  }

  private void read_dont_suggest_db () {
    dont_suggest_link.clear ();
    try {
      var path = Path.build_filename (Environment.get_user_config_dir (), "gnome-contacts", "dont_suggest.db");
      string contents;
      if (FileUtils.get_contents (path, out contents)) {
	var rows = contents.split ("\n");
	foreach (var r in rows) {
	  var ids = r.split (" ");
	  if (ids.length == 2) {
	    dont_suggest_link.set (ids[0], ids[1]);
	  }
	}
      }
    } catch (GLib.Error e) {
      if (!(e is FileError.NOENT))
	warning ("error loading no suggestion db: %s\n", e.message);
    }
  }

  private void write_dont_suggest_db () {
    try {
      var dir = Path.build_filename (Environment.get_user_config_dir (), "gnome-contacts");
      DirUtils.create_with_parents (dir, 0700);
      var path = Path.build_filename (dir, "dont_suggest.db");

      var s = new StringBuilder ();
      foreach (var key in dont_suggest_link.get_keys ()) {
	foreach (var value in dont_suggest_link.get (key)) {
	  s.append_printf ("%s %s\n", key, value);
	}
      }
      FileUtils.set_contents (path, s.str, s.len);
    } catch (GLib.Error e) {
      warning ("error writing no suggestion db: %s\n", e.message);
    }
  }

  public bool may_suggest_link (Contact a, Contact b) {
    foreach (var a_persona in a.individual.personas) {
      foreach (var no_link_uid in dont_suggest_link.get (a_persona.uid)) {
	foreach (var b_persona in b.individual.personas) {
	  if (b_persona.uid == no_link_uid)
	    return false;
	}
      }
    }
    foreach (var b_persona in b.individual.personas) {
      foreach (var no_link_uid in dont_suggest_link.get (b_persona.uid)) {
	foreach (var a_persona in a.individual.personas) {
	  if (a_persona.uid == no_link_uid)
	    return false;
	}
      }
    }
    return true;
  }

  public void add_no_suggest_link (Contact a, Contact b) {
    var persona1 = a.get_personas_for_display ().to_array ()[0];
    var persona2 = b.get_personas_for_display ().to_array ()[0];
    dont_suggest_link.set (persona1.uid, persona2.uid);
    write_dont_suggest_db ();
  }

  construct {
    contacts = new Gee.ArrayList<Contact>();

    dont_suggest_link = new Gee.HashMultiMap<string, string> ();
    read_dont_suggest_db ();

    backend_store = BackendStore.dup ();
    backend_store.backend_available.connect ((backend) => {
	if (backend.name == "eds") {
	  backend.persona_store_added.connect (() => {
	      eds_persona_store_changed ();
	    });
	  backend.persona_store_removed.connect (() => {
	      eds_persona_store_changed ();
	    });
	}
      });

    aggregator = IndividualAggregator.dup ();
    aggregator.notify["is-quiescent"].connect ( (obj, pspec) => {
	// We seem to get this before individuals_changed, so hack around it
	Idle.add( () => {
	    this.quiescent ();
	    return false;
	  });
      });

    aggregator.notify["is-prepared"].connect ( (obj, pspec) => {
	Idle.add( () => {
	    this.prepared ();
	    return false;
	  });
      });

    aggregator.individuals_changed_detailed.connect ( (changes) =>   {
	// Note: Apparently the current implementation doesn't necessarily pick
	// up unlinked individual as replacements.

	var replaced_individuals = new HashMap<Individual?, Individual?> ();

	// Pick best replacements at joins
	foreach (var old_individual in changes.get_keys ()) {
	  if (old_individual == null)
	    continue;
	  foreach (var new_individual in changes.get (old_individual)) {
	    if (new_individual == null)
	      continue;
	    if (!replaced_individuals.has_key (new_individual) ||
		individual_should_replace_at_join (old_individual)) {
	      replaced_individuals.set (new_individual, old_individual);
	    }
	  }
	}

	foreach (var old_individual in changes.get_keys ()) {
	  HashSet<Individual>? replacements = null;
	  foreach (var new_individual in changes.get (old_individual)) {
	    if (old_individual != null && new_individual != null &&
		replaced_individuals.get (new_individual) == old_individual) {
	      if (replacements == null)
		replacements = new HashSet<Individual> ();
	      replacements.add (new_individual);
	    } else if (old_individual != null) {
	      /* Removing an old individual. */
	      var c = Contact.from_individual (old_individual);
	      this.remove (c);
	    } else if (new_individual != null) {
	      /* Adding a new individual. */
	      this.add (new Contact (this, new_individual));
	    }
	  }

	  // This old_individual was split up into one or more new ones
	  // We have to pick one to be the one that we keep around
	  // in the old Contact, the rest gets new Contacts
	  // This is important to get right, as we might be displaying
	  // the contact and unlink a specific persona from the contact
	  if (replacements != null) {
	    Individual? main_individual = null;
	    foreach (var i in replacements) {
	      main_individual = i;
	      // If this was marked as being possible to replace the
	      // contact on split then we can otherwise bail immediately
	      // Otherwise need to look for other possible better
	      // replacements that we should reuse
	      if (individual_can_replace_at_split (i))
		break;
	    }

	    var c = Contact.from_individual (old_individual);
	    c.replace_individual (main_individual);
	    foreach (var i in replacements) {
	      if (i != main_individual) {
		/* Already replaced this old_individual, i.e. we're splitting
		   old_individual. We just make this a new one. */
		this.add (new Contact (this, i));
	      }
	    }
	  }
	}
      });
    aggregator.prepare.begin ();

    check_call_capabilities.begin ();
  }

  private void contact_changed_cb (Contact c) {
    changed (c);
  }

  public delegate bool ContactMatcher (Contact c);
  public async Contact? find_contact (ContactMatcher matcher) {
    foreach (var c in contacts) {
      if (matcher (c))
	return c;
    }
    if (is_quiescent)
      return null;

    Contact? matched = null;
    ulong id1, id2, id3;
    SourceFunc callback = find_contact.callback;
    id1 = this.changed.connect ( (c) => {
	if (matcher (c)) {
	  matched = c;
	  callback ();
	}
      });
    id2 = this.added.connect ( (c) => {
	if (matcher (c)) {
	  matched = c;
	  callback ();
	}
      });
    id3 = this.quiescent.connect ( () => {
	callback();
      });
    yield;
    this.disconnect (id1);
    this.disconnect (id2);
    this.disconnect (id3);
    return matched;
  }

  public Contact? find_contact_with_persona (Persona persona) {
    foreach (var contact in contacts) {
      if (contact.individual.personas.contains (persona))
	return contact;
    }
    return null;
  }

  public Collection<Contact> get_contacts () {
    return contacts.read_only_view;
  }

  public bool is_empty () {
    foreach (var contact in contacts) {
      if (!contact.is_hidden)
	return false;
    }
    return true;
  }

  private void add (Contact c) {
    contacts.add (c);
    c.changed.connect (contact_changed_cb);
    added (c);
  }

  private void remove (Contact c) {
    c.changed.disconnect (contact_changed_cb);

    var i = contacts.index_of (c);
    if (i != contacts.size - 1)
      contacts.set (i, contacts.get (contacts.size - 1));
    contacts.remove_at (contacts.size - 1);

    removed (c);
  }

  // TODO: listen for changes in Account#URISchemes
  private async void check_call_capabilities () {
    this.calling_accounts = new Gee.HashMap<string, Account> ();
    var account_manager = AccountManager.dup ();

    try {
      yield account_manager.prepare_async (null);

      account_manager.account_enabled.connect (this.check_account_caps);
      account_manager.account_disabled.connect (this.check_account_caps);

      foreach (var account in account_manager.get_valid_accounts ()) {
	yield this.check_account_caps (account);
      }
    } catch (GLib.Error e) {
      warning ("Unable to check accounts caps %s", e.message);
    }
  }

  private async void check_account_caps (Account account) {
    GLib.Quark addressing = Account.get_feature_quark_addressing ();
    if (!account.is_prepared (addressing)) {
      GLib.Quark[] features = { addressing };
      try {
	yield account.prepare_async (features);
      } catch (GLib.Error e) {
	warning ("Unable to prepare account %s", e.message);
      }
    }

    if (account.is_prepared (addressing)) {
      var k = account.get_object_path ();
      if (account.is_enabled () &&
	  account.associated_with_uri_scheme ("tel")) {
	this.calling_accounts.set (k, account);
      } else {
	this.calling_accounts.unset (k);
      }
    }
  }
}
