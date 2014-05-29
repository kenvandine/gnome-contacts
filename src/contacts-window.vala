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

using Gee;
using Gtk;
using Folks;

[GtkTemplate (ui = "/org/gnome/contacts/contacts-window.ui")]
public class Contacts.Window : Gtk.ApplicationWindow {
  [GtkChild]
  private Grid content_grid;
  [GtkChild]
  private Box loading_box;
  [GtkChild]
  private SizeGroup left_pane_size_group;
  [GtkChild]
  private HeaderBar left_toolbar;
  [GtkChild]
  private HeaderBar right_toolbar;
  [GtkChild]
  private Overlay overlay;
  [GtkChild]
  private ContactPane contact_pane;
  [GtkChild]
  private ToggleButton select_button;
  [GtkChild]
  private Button edit_button;
  [GtkChild]
  private Button done_button;

  [GtkChild]
  private Stack view_switcher;

  [GtkChild]
  private Box content_header_bar;

  [GtkChild]
  private HeaderBar setup_header_bar;
  [GtkChild]
  private Button setup_done_button;
  [GtkChild]
  private Button setup_cancel_button;
  [GtkChild]
  private AccountsList setup_accounts_list;

  private ListPane list_pane;

  /* FIXME: remove from public what it is not needed */
  [GtkChild]
  public Button add_button;

  public string left_title {
    get {
      return left_toolbar.get_title ();
    }
    set {
      left_toolbar.set_title (value);
    }
  }

  public string right_title {
    get {
      return right_toolbar.get_title ();
    }
    set {
      right_toolbar.set_title (value);
    }
  }

  public Store store {
    get; construct set;
  }

  public Window (Gtk.Application app, Store contacts_store) {
    Object (application: app, store: contacts_store);
    debug ("everyone creation: finalized already!!!");

    contact_pane.store = contacts_store;

    /* FIXME: order me, debug code */
    if (true) { /* setup is done ? */
      view_switcher.visible_child_name = "content-view";
      set_titlebar (content_header_bar);
    } else {
      /* here we need to wait for Store::prepare */
      view_switcher.visible_child_name = "setup-view";
      set_titlebar (setup_header_bar);

      setup_accounts_list.update_contents (false);

      setup_done_button.clicked.connect (() => {
	  /* Here we need to wait for Store::quiescent */
	  view_switcher.visible_child_name = "content-view";
	  set_titlebar (content_header_bar);

          Timeout.add (5000, () => {
	      this.set_list_pane ();
	      return false;
	    });
	});
      setup_cancel_button.clicked.connect (() => {
	  destroy ();
	});
    }

    init_content_widgets ();
  }

  public void set_list_pane () {
    /* FIXME: if no contact is loaded per backend, I must place a sign
     * saying "import your contacts/add online account" */
    if (list_pane != null)
      return;

    list_pane = new ListPane (store);
    list_pane.selection_changed.connect (list_pane_selection_changed_cb);
    list_pane.link_contacts.connect (list_pane_link_contacts_cb);
    list_pane.delete_contacts.connect (list_pane_delete_contacts_cb);

    list_pane.contacts_marked.connect ((nr_contacts) => {
	if (nr_contacts == 0) {
	  left_title = _("Select");
	} else {
	  left_title = ngettext ("%d Selected",
				 "%d Selected", nr_contacts).printf (nr_contacts);
	}
      });

    left_pane_size_group.add_widget (list_pane);
    left_pane_size_group.remove_widget (loading_box);
    loading_box.destroy ();

    content_grid.attach (list_pane, 0, 0, 1, 1);
    list_pane.show ();
  }

  public void activate_selection_mode (bool active) {
    if (active) {
      add_button.hide ();
      edit_button.hide ();

      left_toolbar.get_style_context ().add_class ("selection-mode");
      right_toolbar.get_style_context ().add_class ("selection-mode");

      left_toolbar.set_title (_("Select"));
      right_toolbar.show_close_button = false;

      list_pane.show_selection ();
    } else {
      add_button.show ();

      left_toolbar.get_style_context ().remove_class ("selection-mode");
      right_toolbar.get_style_context ().remove_class ("selection-mode");

      left_toolbar.set_title (_("All Contacts"));
      right_toolbar.show_close_button = true;

      list_pane.hide_selection ();

      /* could be no contact selected whatsoever */
      if (contact_pane.contact != null)
	edit_button.show ();
    }
  }

  public void activate_edit_mode (bool active) {
    if (active) {
	if (contact_pane.contact == null)
	  return;

	var name = contact_pane.contact.display_name;
	right_title = _("Editing %s").printf (name);

	left_toolbar.get_style_context ().add_class ("selection-mode");
	right_toolbar.get_style_context ().add_class ("selection-mode");

	edit_button.hide ();
	done_button.show ();
	contact_pane.set_edit_mode (true);
    } else {
	done_button.hide ();
	edit_button.show ();
	contact_pane.set_edit_mode (false);

	left_toolbar.get_style_context ().remove_class ("selection-mode");
	right_toolbar.get_style_context ().remove_class ("selection-mode");

	if (contact_pane.contact != null)
	  right_title = contact_pane.contact.display_name;
	else
	  right_title = "";
    }

    add_button.visible = !active;
    select_button.visible = !active;
    right_toolbar.show_close_button = !active;
  }

  public void add_notification (Widget notification) {
    overlay.add_overlay (notification);
  }

  public void set_shown_contact (Contact? c) {
    /* FIXME: ask the user to leave edit-mode and act accordingly */
    if (contact_pane.on_edit_mode) {
      activate_edit_mode (false);
    }

    contact_pane.show_contact (c, false);

    /* clearing right_toolbar */
    if (c != null)
      right_title = c.display_name;
    else
      right_title = "";

    edit_button.visible = (c != null) && !select_button.active;
  }

  /* internal API */
  void init_content_widgets () {
    string layout_desc;
    string[] tokens;

    layout_desc = Gtk.Settings.get_default ().gtk_decoration_layout;
    tokens = layout_desc.split (":", 2);
    if (tokens != null) {
      right_toolbar.decoration_layout = ":%s".printf (tokens[1]);
      left_toolbar.decoration_layout = tokens[0];
    }

    select_button.toggled.connect (() => {
	activate_selection_mode (select_button.active);
      });

    edit_button.clicked.connect (() => {
	activate_edit_mode (true);
      });

    done_button.clicked.connect (() => {
	activate_edit_mode (false);
      });
  }

  [GtkCallback]
  bool key_press_event_cb (Gdk.EventKey event) {
    if ((event.keyval == Gdk.keyval_from_name ("q")) &&
        ((event.state & Gdk.ModifierType.CONTROL_MASK) != 0)) {
      // Clear the contacts so any changed information is stored
      contact_pane.show_contact (null);
      destroy ();
    } else if (((event.keyval == Gdk.Key.s) ||
                (event.keyval == Gdk.Key.f)) &&
               ((event.state & Gdk.ModifierType.CONTROL_MASK) != 0)) {
      Utils.grab_entry_focus_no_select (list_pane.filter_entry);
    } else if (event.length >= 1 &&
               Gdk.keyval_to_unicode (event.keyval) != 0 &&
               (event.state & Gdk.ModifierType.CONTROL_MASK) == 0 &&
               (event.state & Gdk.ModifierType.MOD1_MASK) == 0 &&
               (event.keyval != Gdk.Key.Escape) &&
               (event.keyval != Gdk.Key.Tab) &&
               (event.keyval != Gdk.Key.BackSpace) ) {
      Utils.grab_entry_focus_no_select (list_pane.filter_entry);
      propagate_key_event (event);
    }

    return false;
  }

  [GtkCallback]
  bool delete_event_cb (Gdk.EventAny event) {
    // Clear the contacts so any changed information is stored
    contact_pane.show_contact (null);
    return false;
  }

  void list_pane_selection_changed_cb (Contact? new_selection) {
    set_shown_contact (new_selection);
  }

  void list_pane_link_contacts_cb (LinkedList<Contact> contact_list) {
    /* getting out of selection mode */
    set_shown_contact (null);
    select_button.set_active (false);

    LinkOperation2 operation = null;
    link_contacts_list.begin (contact_list, (obj, result) => {
        operation = link_contacts_list.end (result);
      });

    var notification = new Gd.Notification ();
    notification.timeout = 5;

    var g = new Grid ();
    g.set_column_spacing (8);
    notification.add (g);

    string msg = ngettext ("%d contacts linked",
                           "%d contacts linked",
                           contact_list.size).printf (contact_list.size);

    var b = new Button.with_mnemonic (_("_Undo"));
    g.add (new Label (msg));
    g.add (b);

    notification.show_all ();
    add_notification (notification);

    /* signal handlers */
    b.clicked.connect ( () => {
        /* here, we will unlink the thing in question */
        operation.undo.begin ();

        notification.dismiss ();
      });
  }

  void list_pane_delete_contacts_cb (LinkedList<Contact> contact_list) {
    /* getting out of selection mode */
    set_shown_contact (null);
    select_button.set_active (false);

    var notification = new Gd.Notification ();
    notification.timeout = 5;

    var g = new Grid ();
    g.set_column_spacing (8);
    notification.add (g);

    string msg = ngettext ("%d contact deleted",
                           "%d contacts deleted",
                           contact_list.size).printf (contact_list.size);

    var b = new Button.with_mnemonic (_("_Undo"));
    g.add (new Label (msg));
    g.add (b);

    notification.show_all ();
    add_notification (notification);

    /* signal handlers */
    bool really_delete = true;
    notification.dismissed.connect ( () => {
        if (really_delete) {
          foreach (var c in contact_list) {
            c.remove_personas.begin ();
          }
        }
      });
    b.clicked.connect ( () => {
        really_delete = false;
        notification.dismiss ();
	foreach (var c in contact_list) {
	  c.show ();
	}
	set_shown_contact (contact_list.last ());
      });
  }

  [GtkCallback]
  void contact_pane_delete_contact_cb (Contact contact) {
    /* unsetting edit-mode */
    set_shown_contact (null);
    select_button.set_active (false);

    var notification = new Gd.Notification ();
    notification.timeout = 5;

    var g = new Grid ();
    g.set_column_spacing (8);
    notification.add (g);

    var label = new Label (_("Contact deleted: \"%s\"").printf (contact.display_name));
    label.set_max_width_chars (45);
    label.set_ellipsize (Pango.EllipsizeMode.END);
    var b = new Button.with_mnemonic (_("_Undo"));
    g.add (label);
    g.add (b);

    bool really_delete = true;
    notification.show_all ();
    notification.dismissed.connect ( () => {
        if (really_delete)
          contact.remove_personas.begin ( () => {
              contact.show ();
            });
      });
    b.clicked.connect ( () => {
        really_delete = false;
        notification.dismiss ();
        contact.show ();
        set_shown_contact (contact);
      });
    add_notification (notification);
  }

  [GtkCallback]
  void contact_pane_contacts_linked_cb (string? main_contact, string linked_contact, LinkOperation operation) {
    var notification = new Gd.Notification ();
    notification.timeout = 5;

    var g = new Grid ();
    g.set_column_spacing (8);
    notification.add (g);

    string msg;
    if (main_contact != null)
      msg = _("%s linked to %s").printf (main_contact, linked_contact);
    else
      msg = _("%s linked to the contact").printf (linked_contact);

    var b = new Button.with_mnemonic (_("_Undo"));
    g.add (new Label (msg));
    g.add (b);

    notification.show_all ();
    b.clicked.connect ( () => {
	notification.dismiss ();
	operation.undo.begin ();
      });
    add_notification (notification);
  }
}
