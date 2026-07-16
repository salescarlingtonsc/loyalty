export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      appointment_services: {
        Row: {
          appointment_id: string
          price_cents: number
          service_id: string
        }
        Insert: {
          appointment_id: string
          price_cents: number
          service_id: string
        }
        Update: {
          appointment_id?: string
          price_cents?: number
          service_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "appointment_services_appointment_id_fkey"
            columns: ["appointment_id"]
            isOneToOne: false
            referencedRelation: "appointments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "appointment_services_service_id_fkey"
            columns: ["service_id"]
            isOneToOne: false
            referencedRelation: "services"
            referencedColumns: ["id"]
          },
        ]
      }
      appointments: {
        Row: {
          client_id: string
          created_at: string
          ends_at: string
          id: string
          salon_id: string
          staff_id: string | null
          starts_at: string
          status: string
          total_cents: number
        }
        Insert: {
          client_id: string
          created_at?: string
          ends_at: string
          id?: string
          salon_id: string
          staff_id?: string | null
          starts_at: string
          status?: string
          total_cents?: number
        }
        Update: {
          client_id?: string
          created_at?: string
          ends_at?: string
          id?: string
          salon_id?: string
          staff_id?: string | null
          starts_at?: string
          status?: string
          total_cents?: number
        }
        Relationships: [
          {
            foreignKeyName: "appointments_client_id_fkey"
            columns: ["client_id"]
            isOneToOne: false
            referencedRelation: "clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "appointments_salon_id_fkey"
            columns: ["salon_id"]
            isOneToOne: false
            referencedRelation: "salons"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "appointments_staff_id_fkey"
            columns: ["staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
        ]
      }
      clients: {
        Row: {
          created_at: string
          email: string | null
          full_name: string
          id: string
          notes: string | null
          phone: string | null
          salon_id: string
        }
        Insert: {
          created_at?: string
          email?: string | null
          full_name: string
          id?: string
          notes?: string | null
          phone?: string | null
          salon_id: string
        }
        Update: {
          created_at?: string
          email?: string | null
          full_name?: string
          id?: string
          notes?: string | null
          phone?: string | null
          salon_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "clients_salon_id_fkey"
            columns: ["salon_id"]
            isOneToOne: false
            referencedRelation: "salons"
            referencedColumns: ["id"]
          },
        ]
      }
      credit_ledger: {
        Row: {
          amount_cents: number
          client_id: string
          created_at: string
          entry_type: string
          id: string
          reference: string | null
          salon_id: string
        }
        Insert: {
          amount_cents: number
          client_id: string
          created_at?: string
          entry_type: string
          id?: string
          reference?: string | null
          salon_id: string
        }
        Update: {
          amount_cents?: number
          client_id?: string
          created_at?: string
          entry_type?: string
          id?: string
          reference?: string | null
          salon_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "credit_ledger_client_id_fkey"
            columns: ["client_id"]
            isOneToOne: false
            referencedRelation: "clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_ledger_salon_id_fkey"
            columns: ["salon_id"]
            isOneToOne: false
            referencedRelation: "salons"
            referencedColumns: ["id"]
          },
        ]
      }
      gift_cards: {
        Row: {
          balance_cents: number
          code: string
          created_at: string
          id: string
          initial_cents: number
          purchaser_client_id: string | null
          recipient_email: string | null
          salon_id: string
          status: string
        }
        Insert: {
          balance_cents: number
          code: string
          created_at?: string
          id?: string
          initial_cents: number
          purchaser_client_id?: string | null
          recipient_email?: string | null
          salon_id: string
          status?: string
        }
        Update: {
          balance_cents?: number
          code?: string
          created_at?: string
          id?: string
          initial_cents?: number
          purchaser_client_id?: string | null
          recipient_email?: string | null
          salon_id?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "gift_cards_purchaser_client_id_fkey"
            columns: ["purchaser_client_id"]
            isOneToOne: false
            referencedRelation: "clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gift_cards_salon_id_fkey"
            columns: ["salon_id"]
            isOneToOne: false
            referencedRelation: "salons"
            referencedColumns: ["id"]
          },
        ]
      }
      leads: {
        Row: {
          created_at: string
          email: string
          id: string
          message: string | null
          name: string | null
          source: string
        }
        Insert: {
          created_at?: string
          email: string
          id?: string
          message?: string | null
          name?: string | null
          source?: string
        }
        Update: {
          created_at?: string
          email?: string
          id?: string
          message?: string | null
          name?: string | null
          source?: string
        }
        Relationships: []
      }
      loyalty_programs: {
        Row: {
          active: boolean
          earn_rate_bps: number
          id: string
          kind: string
          reward_credit_cents: number
          salon_id: string
          stamp_target: number | null
        }
        Insert: {
          active?: boolean
          earn_rate_bps?: number
          id?: string
          kind: string
          reward_credit_cents?: number
          salon_id: string
          stamp_target?: number | null
        }
        Update: {
          active?: boolean
          earn_rate_bps?: number
          id?: string
          kind?: string
          reward_credit_cents?: number
          salon_id?: string
          stamp_target?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "loyalty_programs_salon_id_fkey"
            columns: ["salon_id"]
            isOneToOne: true
            referencedRelation: "salons"
            referencedColumns: ["id"]
          },
        ]
      }
      products: {
        Row: {
          active: boolean
          id: string
          name: string
          retail_price_cents: number
          salon_id: string
          sku: string | null
        }
        Insert: {
          active?: boolean
          id?: string
          name: string
          retail_price_cents?: number
          salon_id: string
          sku?: string | null
        }
        Update: {
          active?: boolean
          id?: string
          name?: string
          retail_price_cents?: number
          salon_id?: string
          sku?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "products_salon_id_fkey"
            columns: ["salon_id"]
            isOneToOne: false
            referencedRelation: "salons"
            referencedColumns: ["id"]
          },
        ]
      }
      referrals: {
        Row: {
          created_at: string
          id: string
          qualified_at: string | null
          referred_client_id: string | null
          referrer_client_id: string
          reward_cents: number
          salon_id: string
          status: string
        }
        Insert: {
          created_at?: string
          id?: string
          qualified_at?: string | null
          referred_client_id?: string | null
          referrer_client_id: string
          reward_cents?: number
          salon_id: string
          status?: string
        }
        Update: {
          created_at?: string
          id?: string
          qualified_at?: string | null
          referred_client_id?: string | null
          referrer_client_id?: string
          reward_cents?: number
          salon_id?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "referrals_referred_client_id_fkey"
            columns: ["referred_client_id"]
            isOneToOne: false
            referencedRelation: "clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "referrals_referrer_client_id_fkey"
            columns: ["referrer_client_id"]
            isOneToOne: false
            referencedRelation: "clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "referrals_salon_id_fkey"
            columns: ["salon_id"]
            isOneToOne: false
            referencedRelation: "salons"
            referencedColumns: ["id"]
          },
        ]
      }
      salons: {
        Row: {
          created_at: string
          currency: string
          id: string
          name: string
          slug: string
        }
        Insert: {
          created_at?: string
          currency?: string
          id?: string
          name: string
          slug: string
        }
        Update: {
          created_at?: string
          currency?: string
          id?: string
          name?: string
          slug?: string
        }
        Relationships: []
      }
      services: {
        Row: {
          active: boolean
          duration_min: number
          id: string
          name: string
          price_cents: number
          salon_id: string
        }
        Insert: {
          active?: boolean
          duration_min: number
          id?: string
          name: string
          price_cents: number
          salon_id: string
        }
        Update: {
          active?: boolean
          duration_min?: number
          id?: string
          name?: string
          price_cents?: number
          salon_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "services_salon_id_fkey"
            columns: ["salon_id"]
            isOneToOne: false
            referencedRelation: "salons"
            referencedColumns: ["id"]
          },
        ]
      }
      staff: {
        Row: {
          created_at: string
          full_name: string | null
          id: string
          role: string
          salon_id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          full_name?: string | null
          id?: string
          role: string
          salon_id: string
          user_id: string
        }
        Update: {
          created_at?: string
          full_name?: string | null
          id?: string
          role?: string
          salon_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "staff_salon_id_fkey"
            columns: ["salon_id"]
            isOneToOne: false
            referencedRelation: "salons"
            referencedColumns: ["id"]
          },
        ]
      }
      stock_batches: {
        Row: {
          expires_on: string | null
          id: string
          product_id: string
          qty: number
          received_on: string
        }
        Insert: {
          expires_on?: string | null
          id?: string
          product_id: string
          qty: number
          received_on?: string
        }
        Update: {
          expires_on?: string | null
          id?: string
          product_id?: string
          qty?: number
          received_on?: string
        }
        Relationships: [
          {
            foreignKeyName: "stock_batches_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      client_credit_balance: {
        Row: {
          balance_cents: number | null
          client_id: string | null
          salon_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "credit_ledger_client_id_fkey"
            columns: ["client_id"]
            isOneToOne: false
            referencedRelation: "clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_ledger_salon_id_fkey"
            columns: ["salon_id"]
            isOneToOne: false
            referencedRelation: "salons"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Functions: {
      [_ in never]: never
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
